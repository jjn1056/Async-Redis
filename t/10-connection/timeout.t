# t/10-connection/timeout.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use IO::Async::Timer::Periodic;
use Future::IO::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

# Helper: await a Future and return its result (throws on failure)
sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

subtest 'constructor accepts timeout parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host                    => 'localhost',
        connect_timeout         => 5,
        read_timeout            => 10,
        write_timeout           => 10,
        request_timeout         => 3,
        blocking_timeout_buffer => 2,
    );

    is($redis->{connect_timeout}, 5, 'connect_timeout');
    is($redis->{read_timeout}, 10, 'read_timeout');
    is($redis->{write_timeout}, 10, 'write_timeout');
    is($redis->{request_timeout}, 3, 'request_timeout');
    is($redis->{blocking_timeout_buffer}, 2, 'blocking_timeout_buffer');
};

subtest 'default timeout values' => sub {
    my $redis = Future::IO::Redis->new(host => 'localhost');

    is($redis->{connect_timeout}, 10, 'default connect_timeout');
    is($redis->{read_timeout}, 30, 'default read_timeout');
    is($redis->{request_timeout}, 5, 'default request_timeout');
    is($redis->{blocking_timeout_buffer}, 2, 'default blocking_timeout_buffer');
};

subtest 'connect timeout fires on unreachable host' => sub {
    my $start = time();

    my $redis = Future::IO::Redis->new(
        host            => '10.255.255.1',  # non-routable IP
        connect_timeout => 0.5,
    );

    my $error;
    my $f = $redis->connect;
    $loop->await($f);
    eval { $f->get };  # ->get throws on failure
    $error = $@;

    my $elapsed = time() - $start;

    ok($error, 'connect failed');
    ok($elapsed >= 0.4, "waited at least 0.4s (got ${elapsed}s)");
    ok($elapsed < 1.5, "didn't wait too long (got ${elapsed}s)");
};

subtest 'event loop not blocked during connect timeout' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.05,
        on_tick  => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    my $redis = Future::IO::Redis->new(
        host            => '10.255.255.1',
        connect_timeout => 0.3,
    );

    my $start = time();
    my $f = $redis->connect;
    $loop->await($f);
    eval { $f->get };  # convert failure to exception (ignored)
    my $elapsed = time() - $start;

    $timer->stop;
    $loop->remove($timer);

    # Should have ticked multiple times during the 0.3s wait
    ok(@ticks >= 3, "timer ticked " . scalar(@ticks) . " times during ${elapsed}s timeout");
};

# Tests requiring actual Redis connection
SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 4 unless $test_redis;
    $test_redis->disconnect;

    subtest 'request timeout fires on slow command' => sub {
        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 0.3,
        );
        await_f($redis->connect);

        my $start = time();
        my $error;
        eval {
            # DEBUG SLEEP causes Redis to block for N seconds
            await_f($redis->command('DEBUG', 'SLEEP', '2'));
        };
        $error = $@;
        my $elapsed = time() - $start;

        ok($error, 'command failed');
        like("$error", qr/timed?\s*out/i, 'error mentions timeout');
        ok($elapsed >= 0.2, "waited at least 0.2s (got ${elapsed}s)");
        ok($elapsed < 1.0, "timed out before command finished (got ${elapsed}s)");

        $redis->disconnect;
    };

    subtest 'event loop not blocked during request timeout' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.05,
            on_tick  => sub { push @ticks, time() },
        );
        $loop->add($timer);
        $timer->start;

        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 0.3,
        );
        await_f($redis->connect);

        eval { await_f($redis->command('DEBUG', 'SLEEP', '2')) };

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "timer ticked " . scalar(@ticks) . " times during timeout");

        $redis->disconnect;
    };

    subtest 'blocking command uses extended timeout' => sub {
        my $redis = Future::IO::Redis->new(
            host                    => $ENV{REDIS_HOST} // 'localhost',
            request_timeout         => 1,
            blocking_timeout_buffer => 1,
        );
        await_f($redis->connect);

        # Clean up any existing list
        await_f($redis->del('timeout:test:list'));

        my $start = time();
        # BLPOP with 0.5s server timeout
        # Client deadline should be 0.5 + 1 (buffer) = 1.5s
        my $result = await_f($redis->command('BLPOP', 'timeout:test:list', '0.5'));
        my $elapsed = time() - $start;

        # BLPOP returns undef on timeout
        is($result, undef, 'BLPOP returned undef (server timeout)');
        ok($elapsed >= 0.4, "waited for server timeout (${elapsed}s)");
        ok($elapsed < 1.0, "didn't hit client timeout (${elapsed}s)");

        $redis->disconnect;
    };

    subtest 'normal commands work within timeout' => sub {
        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 5,
        );
        await_f($redis->connect);

        # Normal commands should complete well within timeout
        my $result = await_f($redis->command('PING'));
        is($result, 'PONG', 'PING works');

        await_f($redis->command('SET', 'timeout:test:key', 'value'));
        my $value = await_f($redis->command('GET', 'timeout:test:key'));
        is($value, 'value', 'GET/SET work');

        # Cleanup
        await_f($redis->del('timeout:test:key'));
        $redis->disconnect;
    };
}

done_testing;
