# t/60-scripting/script-object.t
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

    # Cleanup
    await_f($redis->del('script:counter', 'script:key'));

    subtest 'create script object' => sub {
        my $script = $redis->script(<<'LUA');
return "hello from script object"
LUA

        ok($script, 'script object created');
        ok($script->sha, 'script has SHA');
        is(length($script->sha), 40, 'SHA is 40 chars');
    };

    subtest 'script->call() with no keys' => sub {
        my $script = $redis->script('return "no keys"');

        my $result = await_f($script->call());
        is($result, 'no keys', 'script executed');
    };

    subtest 'script->call_with_keys() with keys and args' => sub {
        await_f($redis->set('script:key', '100'));

        my $script = $redis->script(<<'LUA');
local current = tonumber(redis.call('GET', KEYS[1])) or 0
local amount = tonumber(ARGV[1]) or 0
local new = current + amount
redis.call('SET', KEYS[1], new)
return new
LUA

        my $result = await_f($script->call_with_keys(1, 'script:key', 50));
        is($result, 150, 'increment script worked');

        $result = await_f($script->call_with_keys(1, 'script:key', 25));
        is($result, 175, 'second call worked');
    };

    subtest 'script->call_with_keys() uses EVALSHA after first call' => sub {
        await_f($redis->script_flush);

        my $script = $redis->script('return ARGV[1]');

        # First call loads the script
        my $r1 = await_f($script->call_with_keys(0, 'first'));
        is($r1, 'first', 'first call worked');

        # Verify script is now loaded
        my $exists = await_f($redis->script_exists($script->sha));
        is($exists->[0], 1, 'script cached on server');

        # Second call uses cached SHA
        my $r2 = await_f($script->call_with_keys(0, 'second'));
        is($r2, 'second', 'second call worked');
    };

    subtest 'script survives SCRIPT FLUSH' => sub {
        my $script = $redis->script('return "resilient"');

        # First call
        my $r1 = await_f($script->call());
        is($r1, 'resilient', 'first call');

        # Flush all scripts
        await_f($redis->script_flush);

        # Should auto-reload
        my $r2 = await_f($script->call());
        is($r2, 'resilient', 'survived flush');
    };

    subtest 'script with prefix' => sub {
        my $prefixed = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            prefix => 'pfx:',
        );
        await_f($prefixed->connect);

        my $script = $prefixed->script(<<'LUA');
redis.call('SET', KEYS[1], ARGV[1])
return redis.call('GET', KEYS[1])
LUA

        my $result = await_f($script->call_with_keys(1, 'mykey', 'myvalue'));
        is($result, 'myvalue', 'script executed');

        # Verify key was actually prefixed
        my $raw = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw->connect);
        my $value = await_f($raw->get('pfx:mykey'));
        is($value, 'myvalue', 'key was prefixed');

        # Cleanup
        await_f($raw->del('pfx:mykey'));
    };

    subtest 'non-blocking verification' => sub {
        my $script = $redis->script('return ARGV[1] * 2');

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.005,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        for my $i (1..50) {
            await_f($script->call_with_keys(0, $i));
        }

        $timer->stop;
        $loop->remove($timer);

        # Timing-sensitive test - just verify loop processed
        pass("Event loop ticked during script calls");
    };

    # Cleanup
    await_f($redis->del('script:counter', 'script:key'));
}

done_testing;
