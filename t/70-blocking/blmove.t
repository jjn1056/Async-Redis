# t/70-blocking/blmove.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use IO::Async::Timer::Periodic;
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

    # Check Redis version supports BLMOVE (6.2+)
    my $info_raw = await_f($redis->command('INFO', 'server'));
    my ($version) = $info_raw =~ /redis_version:(\d+\.\d+)/;
    $version //= '0';
    my ($major, $minor) = split /\./, $version;
    skip "BLMOVE requires Redis 6.2+, got $version", 1
        unless ($major > 6 || ($major == 6 && $minor >= 2));

    # Cleanup
    await_f($redis->del('blmove:src', 'blmove:dst'));

    subtest 'BLMOVE moves element' => sub {
        await_f($redis->rpush('blmove:src', 'a', 'b', 'c'));

        my $result = await_f($redis->blmove('blmove:src', 'blmove:dst', 'RIGHT', 'LEFT', 5));
        is($result, 'c', 'moved rightmost element');

        my $src = await_f($redis->lrange('blmove:src', 0, -1));
        is($src, ['a', 'b'], 'source has remaining elements');

        my $dst = await_f($redis->lrange('blmove:dst', 0, -1));
        is($dst, ['c'], 'destination has moved element');
    };

    subtest 'BLMOVE LEFT RIGHT' => sub {
        await_f($redis->del('blmove:src', 'blmove:dst'));
        await_f($redis->rpush('blmove:src', 'x', 'y', 'z'));

        my $result = await_f($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'RIGHT', 5));
        is($result, 'x', 'moved leftmost element');

        my $dst = await_f($redis->lrange('blmove:dst', 0, -1));
        is($dst, ['x'], 'pushed to right of destination');
    };

    subtest 'BLMOVE waits for source data' => sub {
        await_f($redis->del('blmove:src', 'blmove:dst'));

        # Schedule push after 0.3s
        my $pusher = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($pusher->connect);

        my $push_f = $loop->delay_future(after => 0.3)->then(sub {
            $pusher->rpush('blmove:src', 'delayed');
        });

        my $start = time();
        my $result = await_f($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 5));
        my $elapsed = time() - $start;

        is($result, 'delayed', 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");
    };

    subtest 'BLMOVE returns undef on timeout' => sub {
        await_f($redis->del('blmove:src', 'blmove:dst'));

        my $start = time();
        my $result = await_f($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'non-blocking verification' => sub {
        await_f($redis->del('blmove:src', 'blmove:dst'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $result = await_f($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 1));

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BLMOVE timed out');
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times");
    };

    # Cleanup
    await_f($redis->del('blmove:src', 'blmove:dst'));
}

done_testing;
