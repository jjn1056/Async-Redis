# t/70-blocking/brpop.t
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
    await_f($redis->del('brpop:queue'));

    subtest 'BRPOP returns from right side' => sub {
        await_f($redis->rpush('brpop:queue', 'first', 'second', 'third'));

        my $result = await_f($redis->brpop('brpop:queue', 5));
        is($result, ['brpop:queue', 'third'], 'got rightmost item');

        $result = await_f($redis->brpop('brpop:queue', 5));
        is($result, ['brpop:queue', 'second'], 'got next rightmost');

        # Cleanup
        await_f($redis->del('brpop:queue'));
    };

    subtest 'BRPOP waits for data' => sub {
        await_f($redis->del('brpop:queue'));

        # Schedule push after 0.3s
        my $pusher = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($pusher->connect);

        my $push_f = $loop->delay_future(after => 0.3)->then(sub {
            $pusher->lpush('brpop:queue', 'delayed');
        });

        my $start = time();
        my $result = await_f($redis->brpop('brpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['brpop:queue', 'delayed'], 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");
    };

    subtest 'BRPOP returns undef on timeout' => sub {
        await_f($redis->del('brpop:empty'));

        my $start = time();
        my $result = await_f($redis->brpop('brpop:empty', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'non-blocking verification' => sub {
        await_f($redis->del('brpop:nonblock'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $result = await_f($redis->brpop('brpop:nonblock', 1));

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BRPOP timed out');
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times");
    };

    # Cleanup
    await_f($redis->del('brpop:queue'));
}

done_testing;
