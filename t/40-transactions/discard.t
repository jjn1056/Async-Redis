# t/40-transactions/discard.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
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
    await_f($redis->del('discard:key'));

    subtest 'DISCARD aborts transaction' => sub {
        await_f($redis->set('discard:key', 'original'));

        await_f($redis->multi_start());
        await_f($redis->command('SET', 'discard:key', 'modified'));
        await_f($redis->command('INCR', 'discard:key'));  # Would fail on string
        await_f($redis->discard());

        # Value should be unchanged
        my $value = await_f($redis->get('discard:key'));
        is($value, 'original', 'value unchanged after DISCARD');
    };

    subtest 'commands work after DISCARD' => sub {
        await_f($redis->multi_start());
        await_f($redis->discard());

        # Should be able to use connection normally
        my $result = await_f($redis->set('discard:key', 'after_discard'));
        is($result, 'OK', 'command works after DISCARD');

        my $value = await_f($redis->get('discard:key'));
        is($value, 'after_discard', 'value set correctly');
    };

    subtest 'DISCARD preserves WATCH' => sub {
        await_f($redis->set('discard:key', 'watched'));

        await_f($redis->watch('discard:key'));
        await_f($redis->multi_start());
        await_f($redis->command('SET', 'discard:key', 'in_tx'));
        await_f($redis->discard());

        # Watch should still be active
        ok($redis->watching, 'still watching after DISCARD');

        # Clear watch
        await_f($redis->unwatch());
        ok(!$redis->watching, 'not watching after UNWATCH');
    };

    subtest 'in_multi flag cleared after DISCARD' => sub {
        await_f($redis->multi_start());
        ok($redis->in_multi, 'in_multi true during transaction');

        await_f($redis->discard());
        ok(!$redis->in_multi, 'in_multi false after DISCARD');
    };

    # Cleanup
    await_f($redis->del('discard:key'));
}

done_testing;
