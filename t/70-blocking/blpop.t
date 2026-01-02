# t/70-blocking/blpop.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
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

    # Cleanup
    await_f($redis->del('blpop:queue', 'blpop:queue2', 'blpop:high', 'blpop:low'));

    subtest 'BLPOP returns immediately when data exists' => sub {
        # Push some data first
        await_f($redis->rpush('blpop:queue', 'item1', 'item2'));

        my $start = time();
        my $result = await_f($redis->blpop('blpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['blpop:queue', 'item1'], 'got first item');
        ok($elapsed < 0.5, "returned immediately (${elapsed}s)");

        # Cleanup
        await_f($redis->del('blpop:queue'));
    };

    subtest 'BLPOP waits for data' => sub {
        # Empty the queue
        await_f($redis->del('blpop:queue'));

        # Schedule push after 0.3s using a separate connection
        my $pusher = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($pusher->connect);

        my $push_f = $loop->delay_future(after => 0.3)->then(sub {
            $pusher->rpush('blpop:queue', 'delayed_item');
        });

        my $start = time();
        my $result = await_f($redis->blpop('blpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['blpop:queue', 'delayed_item'], 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");

        # Cleanup
        await_f($redis->del('blpop:queue'));
    };

    subtest 'BLPOP returns undef on timeout' => sub {
        await_f($redis->del('blpop:empty'));

        my $start = time();
        my $result = await_f($redis->blpop('blpop:empty', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'BLPOP with multiple queues (priority order)' => sub {
        await_f($redis->del('blpop:high', 'blpop:low'));
        await_f($redis->rpush('blpop:low', 'low_item'));
        await_f($redis->rpush('blpop:high', 'high_item'));

        my $result = await_f($redis->blpop('blpop:high', 'blpop:low', 5));
        is($result, ['blpop:high', 'high_item'], 'got from first queue with data');

        $result = await_f($redis->blpop('blpop:high', 'blpop:low', 5));
        is($result, ['blpop:low', 'low_item'], 'got from second queue');

        # Cleanup
        await_f($redis->del('blpop:high', 'blpop:low'));
    };

    subtest 'non-blocking verification (CRITICAL)' => sub {
        await_f($redis->del('blpop:nonblock'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,  # 10ms
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $start = time();
        my $result = await_f($redis->blpop('blpop:nonblock', 1));
        my $elapsed = time() - $start;

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BLPOP timed out');
        ok($elapsed >= 0.9, "waited ~1s (${elapsed}s)");

        # CRITICAL: Event loop must tick during BLPOP wait
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times (expected ~100)");
    };

    # Cleanup
    await_f($redis->del('blpop:queue', 'blpop:queue2'));
}

done_testing;
