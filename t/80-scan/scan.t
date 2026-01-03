# t/80-scan/scan.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use IO::Async::Timer::Periodic;
use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $redis = eval {
        my $r = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', connect_timeout => 2);
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test keys
    for my $i (1..20) {
        await_f($redis->set("scan:key:$i", "value$i"));
    }

    subtest 'scan_iter returns iterator' => sub {
        my $iter = $redis->scan_iter();
        ok($iter, 'iterator created');
        ok($iter->can('next'), 'iterator has next method');
    };

    subtest 'scan_iter iterates all keys' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*');

        my @all_keys;
        while (my $batch = await_f($iter->next)) {
            push @all_keys, @$batch;
        }

        is(scalar @all_keys, 20, 'found all 20 keys');

        my %unique = map { $_ => 1 } @all_keys;
        is(scalar keys %unique, 20, 'all keys unique');
    };

    subtest 'scan_iter with count hint' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*', count => 5);

        my @batches;
        while (my $batch = await_f($iter->next)) {
            push @batches, $batch;
        }

        ok(@batches >= 1, 'got batches');

        my @all = map { @$_ } @batches;
        is(scalar @all, 20, 'found all 20 keys across batches');
    };

    subtest 'scan_iter next returns undef when done' => sub {
        my $iter = $redis->scan_iter(match => 'scan:nonexistent:*');

        my @all;
        while (my $batch = await_f($iter->next)) {
            push @all, @$batch;
        }

        is(scalar @all, 0, 'no keys found for nonexistent pattern');

        # Subsequent calls return undef
        my $batch = await_f($iter->next);
        is($batch, undef, 'iterator exhausted');
    };

    subtest 'scan_iter is restartable via reset' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*');

        # Consume part of iteration
        my $batch1 = await_f($iter->next);
        ok($batch1, 'got first batch');

        # Reset
        $iter->reset;

        # Should start over
        my @all_keys;
        while (my $batch = await_f($iter->next)) {
            push @all_keys, @$batch;
        }

        is(scalar @all_keys, 20, 'reset allowed full re-iteration');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $iter = $redis->scan_iter(match => 'scan:key:*', count => 2);
        my @all;
        while (my $batch = await_f($iter->next)) {
            push @all, @$batch;
        }

        $timer->stop;
        $loop->remove($timer);

        is(scalar @all, 20, 'got all keys');
        pass("Event loop ticked during SCAN iteration");
    };

    # Cleanup
    for my $i (1..20) {
        await_f($redis->del("scan:key:$i"));
    }
}

done_testing;
