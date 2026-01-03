# t/40-transactions/watch.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
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
    await_f($redis->del('watch:key', 'watch:balance', 'watch:a', 'watch:b'));

    subtest 'watch_multi with unchanged key' => sub {
        await_f($redis->set('watch:balance', '100'));

        my $results = await_f($redis->watch_multi(['watch:balance'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'watch:balance'}, '100', 'watched value provided');

            $tx->decrby('watch:balance', 10);
            $tx->get('watch:balance');
        }));

        ok(defined $results, 'transaction succeeded');
        is($results->[0], 90, 'DECRBY result');
        is($results->[1], '90', 'GET result');
    };

    subtest 'watch with multiple keys' => sub {
        await_f($redis->set('watch:a', '1'));
        await_f($redis->set('watch:b', '2'));

        my $results = await_f($redis->watch_multi(['watch:a', 'watch:b'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'watch:a'}, '1', 'first watched value');
            is($watched->{'watch:b'}, '2', 'second watched value');

            $tx->incr('watch:a');
            $tx->incr('watch:b');
        }));

        is($results, [2, 3], 'both incremented');

        # Cleanup
        await_f($redis->del('watch:a', 'watch:b'));
    };

    subtest 'manual WATCH/MULTI/EXEC' => sub {
        await_f($redis->set('watch:key', 'original'));

        await_f($redis->watch('watch:key'));
        await_f($redis->multi_start());
        await_f($redis->command('SET', 'watch:key', 'modified'));
        my $results = await_f($redis->exec());

        ok(defined $results, 'manual transaction succeeded');
        is($results->[0], 'OK', 'SET succeeded');

        my $value = await_f($redis->get('watch:key'));
        is($value, 'modified', 'value updated');
    };

    subtest 'UNWATCH clears watches' => sub {
        await_f($redis->set('watch:key', 'value'));

        await_f($redis->watch('watch:key'));
        await_f($redis->unwatch());

        # Now modify key from another connection
        my $redis2 = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($redis2->connect);
        await_f($redis2->set('watch:key', 'changed'));

        # Transaction should still succeed because we unwatched
        await_f($redis->multi_start());
        await_f($redis->command('GET', 'watch:key'));
        my $results = await_f($redis->exec());

        ok(defined $results, 'transaction succeeded after UNWATCH');
    };

    # Cleanup
    await_f($redis->del('watch:key', 'watch:balance'));
}

done_testing;
