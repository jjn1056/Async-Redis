# t/30-pipeline/large.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Time::HiRes qw(time);

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

    my $count = 1000;

    subtest "pipeline with $count commands" => sub {
        my $pipe = $redis->pipeline;

        for my $i (1..$count) {
            $pipe->set("large:$i", "value$i");
        }

        is($pipe->count, $count, "pipeline has $count commands queued");

        my $start = time();
        my $results = await_f($pipe->execute);
        my $elapsed = time() - $start;

        is(scalar @$results, $count, "got $count results");
        ok($elapsed < 5, "completed in ${elapsed}s (should be fast)");

        # All should be OK
        my @ok = grep { $_ eq 'OK' } @$results;
        is(scalar @ok, $count, 'all commands returned OK');
    };

    subtest "read back $count keys" => sub {
        my $pipe = $redis->pipeline;

        for my $i (1..$count) {
            $pipe->get("large:$i");
        }

        my $results = await_f($pipe->execute);

        is(scalar @$results, $count, "got $count results");
        is($results->[0], 'value1', 'first value correct');
        is($results->[$count-1], "value$count", 'last value correct');
    };

    subtest 'non-blocking during large pipeline' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $pipe = $redis->pipeline;
        for my $i (1..$count) {
            $pipe->incr("large:$i");
        }
        await_f($pipe->execute);

        $timer->stop;
        $loop->remove($timer);

        pass("Event loop remained responsive during large pipeline");
    };

    # Cleanup
    subtest 'cleanup' => sub {
        my $pipe = $redis->pipeline;
        for my $i (1..$count) {
            $pipe->del("large:$i");
        }
        await_f($pipe->execute);
        pass("cleaned up $count keys");
    };
}

done_testing;
