# t/40-transactions/watch-conflict.t
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

    # Second connection to modify watched keys
    my $redis2 = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    await_f($redis2->connect);

    # Cleanup
    await_f($redis->del('conflict:key', 'conflict:counter'));

    subtest 'WATCH conflict returns undef' => sub {
        await_f($redis->set('conflict:key', 'original'));

        # Start watching
        await_f($redis->watch('conflict:key'));

        # Another client modifies the key
        await_f($redis2->set('conflict:key', 'modified'));

        # Try to execute transaction
        await_f($redis->multi_start());
        await_f($redis->command('SET', 'conflict:key', 'from_transaction'));
        my $results = await_f($redis->exec());

        is($results, undef, 'EXEC returns undef on WATCH conflict');

        # Verify the other client's value persisted
        my $value = await_f($redis->get('conflict:key'));
        is($value, 'modified', 'other client value persisted');
    };

    subtest 'watch_multi returns undef on conflict' => sub {
        await_f($redis->set('conflict:key', 'original'));

        my $results = await_f($redis->watch_multi(['conflict:key'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'conflict:key'}, 'original', 'got original value');

            # Simulate race: other client modifies between WATCH and EXEC
            await_f($redis2->set('conflict:key', 'raced'));

            $tx->set('conflict:key', 'from_tx');
        }));

        is($results, undef, 'watch_multi returns undef on conflict');

        # Verify race winner
        my $value = await_f($redis->get('conflict:key'));
        is($value, 'raced', 'race condition winner persisted');
    };

    subtest 'retry pattern on conflict' => sub {
        await_f($redis->set('conflict:counter', '0'));

        my $attempts = 0;
        my $success = 0;

        # Retry loop pattern
        while ($attempts < 5 && !$success) {
            $attempts++;

            my $results = await_f($redis->watch_multi(['conflict:counter'], async sub {
                my ($tx, $watched) = @_;

                my $current = $watched->{'conflict:counter'} // 0;

                # On first attempt, simulate a race
                if ($attempts == 1) {
                    await_f($redis2->incr('conflict:counter'));
                }

                $tx->set('conflict:counter', $current + 10);
            }));

            $success = defined $results;
        }

        ok($success, 'eventually succeeded after retry');
        ok($attempts > 1, "needed $attempts attempts");

        my $final = await_f($redis->get('conflict:counter'));
        # Should be 11: redis2 set to 1, then we added 10 to that
        is($final, '11', 'final value includes both modifications');
    };

    # Cleanup
    await_f($redis->del('conflict:key', 'conflict:counter'));
}

done_testing;
