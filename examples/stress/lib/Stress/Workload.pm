package Stress::Workload;
use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Future::IO;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);

# Each run_* function is an async sub that loops until $stop is ready.
# Errors are typed and counted on $metrics; the harness halts only on
# integrity violations, not on per-op errors.

async sub run_kv {
    my %args = @_;
    my $pool      = $args{pool};
    my $metrics   = $args{metrics};
    my $integrity = $args{integrity};
    my $stop      = $args{stop};
    my $buckets   = $args{buckets}    // 64;
    my $prefix    = $args{key_prefix} // 'stress:kv';

    my $seq = 0;

    while (!$stop->is_ready) {
        my $bucket = int rand $buckets;
        my $key    = "${prefix}_b${bucket}";

        if (rand() < 0.5) {
            $seq++;
            my $value = "seq=${seq}:rand=" . int(rand 1_000_000);
            my $t0 = time;
            my $ok = eval {
                await $pool->with(sub {
                    my ($r) = @_;
                    return $r->set($key, $value);
                });
                1;
            };
            $metrics->record_latency('set', time - $t0) if $ok;
            if ($ok) {
                $metrics->incr_op('set');
            } else {
                _record_error($metrics, $@);
            }
        } else {
            my $t0 = time;
            my $val;
            my $ok = eval {
                $val = await $pool->with(sub {
                    my ($r) = @_;
                    return $r->get($key);
                });
                1;
            };
            $metrics->record_latency('get', time - $t0) if $ok;
            if ($ok) {
                $metrics->incr_op('get');
                if (defined $val && $val =~ /^seq=(\d+):/) {
                    $integrity->note_kv_observation("b${bucket}", $1);
                }
            } else {
                _record_error($metrics, $@);
            }
        }

        await Future::IO->sleep(0);
    }
    return;
}

sub _record_error {
    my ($metrics, $err) = @_;
    my $type = (blessed($err) && $err->isa('Async::Redis::Error'))
        ? ref($err)
        : 'Unclassified';
    $metrics->{errors_typed}{$type}++;
    return;
}

async sub run_autopipe {
    my %args = @_;
    my $client     = $args{client};
    my $metrics    = $args{metrics};
    my $stop       = $args{stop};
    my $burst_size = $args{burst_size} // 100;
    my $prefix     = $args{key_prefix} // 'stress:ap';

    my $seq = 0;

    while (!$stop->is_ready) {
        my @futures;
        my $t0 = time;
        for my $i (1 .. $burst_size) {
            $seq++;
            my $key = "${prefix}_${seq}";
            push @futures, $client->set($key, "seq=${seq}");
        }
        my $ok = eval { await Future->wait_all(@futures); 1 };
        if ($ok) {
            my $count = grep { $_->is_done } @futures;
            $metrics->incr_op('set', $count);
            my $elapsed = time - $t0;
            $metrics->record_latency('autopipe_burst', $elapsed);
            for my $f (@futures) {
                next unless $f->is_failed;
                _record_error($metrics, ($f->failure)[0]);
            }
        } else {
            _record_error($metrics, $@);
        }
        await Future::IO->sleep(0);
    }
    return;
}

1;
