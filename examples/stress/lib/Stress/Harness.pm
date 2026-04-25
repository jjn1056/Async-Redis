package Stress::Harness;
use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Future::IO;
use Time::HiRes qw(time);

use Async::Redis;
use Async::Redis::Pool;

use Stress::Metrics;
use Stress::Integrity;
use Stress::Output;
use Stress::Chaos;
use Stress::Workload;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        host             => $args{host},
        port             => $args{port},
        duration_s       => $args{duration_s}        // 0,
        pool_size        => $args{pool_size}         // 8,
        blocker_count    => $args{blocker_count}     // 4,
        kv_buckets       => $args{kv_buckets}        // 64,
        channel_count    => $args{channel_count}     // 16,
        kill_interval    => $args{kill_interval}     // 30,
        recovery_window  => $args{recovery_window}   // 5,
        command_deadline => $args{command_deadline}  // 10,
        verify           => $args{verify}            // 1,
        jsonl_fh         => $args{jsonl_fh}          // \*STDOUT,
        stderr_fh        => $args{stderr_fh}         // \*STDERR,
        quiet            => $args{quiet}             // 0,
        key_prefix       => $args{key_prefix}        // "stress:$$",

        running          => 1,
        metrics          => Stress::Metrics->new,
        integrity        => Stress::Integrity->new,
        reconnect_count  => 0,
        chaos            => undef,
        chaos_run_f      => undef,
        workload_fs      => [],
        worker_stop      => Future->new,
        output           => undef,
        start_time       => 0,
        exit_code        => 0,
        inflight_max     => 0,
        inflight_samples => 0,
        inflight_sum     => 0,
    }, $class;
    $self->{output} = Stress::Output->new(
        jsonl_fh  => $self->{jsonl_fh},
        stderr_fh => $self->{stderr_fh},
        quiet     => $self->{quiet},
    );
    return $self;
}

sub run {
    my ($self) = @_;
    return (async sub { await $self->_run_async })->()->get;
}

async sub _run_async {
    my ($self) = @_;
    $self->{start_time} = time;

    await $self->_setup_clients;
    $self->_install_telemetry_hooks;
    $self->_start_chaos;
    $self->_start_workloads;

    while ($self->{running}) {
        last if $self->{duration_s}
             && (time - $self->{start_time}) >= $self->{duration_s};
        await Future::IO->sleep(1);
        $self->_tick;
        # --no-verify (verify=0) keeps integrity tracking running for
        # observability but stops it from failing the run.
        if ($self->{verify} && $self->{integrity}->violations) {
            $self->{exit_code} = 1;
            last;
        }
    }

    await $self->_shutdown;
    return $self->{exit_code};
}

async sub _setup_clients {
    my ($self) = @_;
    # request_timeout is the per-command deadline; reconnect=1 lets
    # workloads survive CLIENT KILL.
    my %common = (
        host            => $self->{host},
        port            => $self->{port},
        request_timeout => $self->{command_deadline},
        reconnect       => 1,
    );

    $self->{controller} = Async::Redis->new(%common);
    await $self->{controller}->connect;
    await $self->{controller}->client('SETNAME', 'stress-controller');

    $self->{pool} = Async::Redis::Pool->new(
        %common,
        max => $self->{pool_size},
    );

    $self->{autopipe_client} = Async::Redis->new(%common, auto_pipeline => 1);
    await $self->{autopipe_client}->connect;

    $self->{subscriber} = Async::Redis->new(%common);
    await $self->{subscriber}->connect;

    $self->{pattern_sub} = Async::Redis->new(%common);
    await $self->{pattern_sub}->connect;

    $self->{publisher} = Async::Redis->new(%common);
    await $self->{publisher}->connect;

    $self->{pattern_publisher} = Async::Redis->new(%common);
    await $self->{pattern_publisher}->connect;

    $self->{driver} = Async::Redis->new(%common);
    await $self->{driver}->connect;

    $self->{blockers} = [];
    for my $i (1 .. $self->{blocker_count}) {
        my $b = Async::Redis->new(%common);
        await $b->connect;
        push @{ $self->{blockers} }, $b;
    }

    $self->{channels}      = [ map { "$self->{key_prefix}:bus:$_" }     0 .. $self->{channel_count} - 1 ];
    $self->{queue_key}     = "$self->{key_prefix}:queue";
    $self->{pattern_prefix}= "$self->{key_prefix}:pattern";
    return;
}

sub _install_telemetry_hooks {
    my ($self) = @_;
    for my $c ($self->_all_clients) {
        my $prev_on_disconnect = $c->{on_disconnect};
        $c->{on_disconnect} = sub {
            $self->{reconnect_count}++;
            $prev_on_disconnect->(@_) if $prev_on_disconnect;
        };
    }
    return;
}

sub _all_clients {
    my ($self) = @_;
    my @cs = (
        $self->{autopipe_client},
        $self->{subscriber},
        $self->{pattern_sub},
        $self->{publisher},
        $self->{pattern_publisher},
        $self->{driver},
        @{ $self->{blockers} },
    );
    return @cs;
}

sub _start_chaos {
    my ($self) = @_;
    return if !$self->{kill_interval};

    my @targets = (
        [ "autopipe"     => $self->{autopipe_client} ],
        [ "subscriber"   => $self->{subscriber} ],
        [ "pattern_sub"  => $self->{pattern_sub} ],
        [ "publisher"    => $self->{publisher} ],
        [ "pat_pub"      => $self->{pattern_publisher} ],
        [ "driver"       => $self->{driver} ],
    );
    for my $i (0 .. $#{ $self->{blockers} }) {
        push @targets, [ "blocker[$i]" => $self->{blockers}[$i] ];
    }
    $self->{chaos} = Stress::Chaos->new(
        controller      => $self->{controller},
        targets         => \@targets,
        interval        => $self->{kill_interval},
        recovery_window => $self->{recovery_window},
        integrity       => $self->{integrity},
    );
    $self->{chaos_run_f} = $self->{chaos}->run;
    return;
}

sub _start_workloads {
    my ($self) = @_;
    my $stop = $self->{worker_stop};
    push @{ $self->{workload_fs} }, Stress::Workload::run_kv(
        pool       => $self->{pool},
        metrics    => $self->{metrics},
        integrity  => $self->{integrity},
        stop       => $stop,
        buckets    => $self->{kv_buckets},
        key_prefix => "$self->{key_prefix}:kv",
    );
    push @{ $self->{workload_fs} }, Stress::Workload::run_autopipe(
        client     => $self->{autopipe_client},
        metrics    => $self->{metrics},
        integrity  => $self->{integrity},
        stop       => $stop,
        burst_size => 100,
        key_prefix => "$self->{key_prefix}:ap",
    );
    push @{ $self->{workload_fs} }, Stress::Workload::run_blocking_driver(
        client    => $self->{driver},
        metrics   => $self->{metrics},
        integrity => $self->{integrity},
        queue     => $self->{queue_key},
        rate_hz   => 100,
        stop      => $stop,
    );
    for my $b (@{ $self->{blockers} }) {
        push @{ $self->{workload_fs} }, Stress::Workload::run_blocking_consumer(
            client    => $b,
            metrics   => $self->{metrics},
            integrity => $self->{integrity},
            queue     => $self->{queue_key},
            stop      => $stop,
        );
    }
    push @{ $self->{workload_fs} }, Stress::Workload::run_pubsub_subscriber(
        client    => $self->{subscriber},
        channels  => $self->{channels},
        metrics   => $self->{metrics},
        integrity => $self->{integrity},
        stop      => $stop,
    );
    push @{ $self->{workload_fs} }, Stress::Workload::run_pubsub_publisher(
        client   => $self->{publisher},
        channels => $self->{channels},
        metrics  => $self->{metrics},
        stop     => $stop,
        rate_hz  => 100,
    );
    push @{ $self->{workload_fs} }, Stress::Workload::run_pattern_subscriber(
        client    => $self->{pattern_sub},
        pattern   => "$self->{pattern_prefix}:*",
        metrics   => $self->{metrics},
        integrity => $self->{integrity},
        stop      => $stop,
    );
    push @{ $self->{workload_fs} }, Stress::Workload::run_pattern_publisher(
        client    => $self->{pattern_publisher},
        prefix    => $self->{pattern_prefix},
        suffixes  => 8,
        metrics   => $self->{metrics},
        integrity => $self->{integrity},
        stop      => $stop,
        rate_hz   => 50,
    );
    return;
}

sub _tick {
    my ($self) = @_;

    my $now_total = 0;
    my $now_max   = 0;
    for my $c ($self->_all_clients) {
        my $d = scalar @{ $c->{inflight} || [] };
        $now_total += $d;
        $now_max = $d if $d > $now_max;
    }
    $self->{inflight_max} = $now_max if $now_max > $self->{inflight_max};
    $self->{inflight_sum}     += $now_total;
    $self->{inflight_samples} += 1;
    my $inflight_avg = $self->{inflight_samples}
        ? $self->{inflight_sum} / $self->{inflight_samples}
        : 0;

    my $h = $self->{metrics}->harvest;
    $self->{output}->emit_metric({
        elapsed_s           => time - $self->{start_time},
        throughput          => $h->{throughput},
        latency_ms          => $h->{latency_ms},
        errors_typed        => $h->{errors_typed},
        reconnects          => $self->{reconnect_count},
        in_flight_depth_max => $self->{inflight_max},
        in_flight_depth_avg => $inflight_avg,
        integrity           => $self->{integrity}->snapshot,
        chaos               => $self->{chaos} ? $self->{chaos}->snapshot
                                              : { kills_issued => 0, last_victim => undef },
    });
    return;
}

async sub _shutdown {
    my ($self) = @_;
    # 1. Signal stop. Compute-bound workloads exit on next iteration.
    # 2. Brief sleep so workloads in compute phase notice stop.
    # 3. Disconnect clients. Pending I/O awaits fail with typed
    #    Disconnected; their evals catch and the workloads fall through.
    # 4. Wait for workload futures with a hard deadline. If the deadline
    #    fires first, a workload future never unwound — that's a
    #    structured-concurrency contract violation → exit code 2.
    $self->{running} = 0;
    $self->{worker_stop}->done unless $self->{worker_stop}->is_ready;
    $self->{chaos}->stop if $self->{chaos};

    await Future::IO->sleep(0.2);

    eval { $_->disconnect } for $self->_all_clients;
    eval { $self->{controller}->disconnect };
    eval { $self->{pool}->shutdown } if $self->{pool};

    my $all_done = Future->wait_all(@{ $self->{workload_fs} });
    my $deadline = Future::IO->sleep($self->{command_deadline});
    my $race     = Future->wait_any($all_done, $deadline);
    eval { await $race };
    if (!$all_done->is_ready) {
        $self->{exit_code} = 2 unless $self->{exit_code};
    }

    eval { await $self->{chaos_run_f} } if $self->{chaos_run_f};

    my $totals = $self->{metrics}->harvest;
    $self->{output}->emit_summary({
        elapsed_s  => time - $self->{start_time},
        totals     => $totals->{throughput},
        violations => [ $self->{integrity}->violations ],
        kills      => $self->{chaos} ? $self->{chaos}->snapshot->{kills_issued} : 0,
        exit_code  => $self->{exit_code},
    });
    return;
}

sub stop_for_signal {
    my ($self) = @_;
    $self->{running} = 0;
    return;
}

1;
