# t/40-transactions/nested.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis';
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', connect_timeout => 2);
        run { $r->connect };
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'nested MULTI returns error' => sub {
        run { $redis->multi_start() };

        # Trying to start another MULTI should return error
        my $error;
        eval {
            run { $redis->multi_start() };
        };
        $error = $@;

        # Clean up
        run { $redis->discard() };

        ok($error, 'nested MULTI threw error');
        like("$error", qr/MULTI calls can not be nested/i, 'correct error message');
    };

    subtest 'multi() callback prevents nesting' => sub {
        my $error;
        eval {
            await_f($redis->multi(async sub {
                my ($tx) = @_;

                # Try to start nested transaction
                await_f($redis->multi(async sub {
                    my ($tx2) = @_;
                    $tx2->set('nested:key', 'value');
                }));
            }));
        };
        $error = $@;

        ok($error, 'nested multi() threw error');
        like("$error", qr/already in a transaction/i, 'correct error message for nested multi()');
    };

    # The guard covers the whole of multi(), not only its callback: a second
    # multi() issued while the first is still sending its MULTI must not
    # interleave with it.
    subtest 'concurrent multi() calls do not interleave' => sub {
        run { $redis->del('nested:c1', 'nested:c2') };
        my $first  = $redis->multi(async sub { $_[0]->set('nested:c1', 'one') });
        my $second = $redis->multi(async sub { $_[0]->set('nested:c2', 'two') });
        my $first_ok  = eval { await_f($first); 1 };
        my $second_ok = eval { await_f($second); 1 };
        my $second_error = $@;

        ok($first_ok, 'the first transaction commits');
        is(run { $redis->get('nested:c1') }, 'one', 'its write is on the server');
        ok(!$second_ok, 'the second is refused');
        like("$second_error", qr/already in a transaction/i, 'as a nested multi()');
        is(run { $redis->get('nested:c2') }, undef, 'and wrote nothing');
        ok(!$redis->in_multi, 'not in MULTI afterwards');
        run { $redis->del('nested:c1', 'nested:c2') };
    };

    subtest 'connection usable after nested error' => sub {
        # Connection should still work
        my $result = run { $redis->ping };
        is($result, 'PONG', 'connection still usable');
    };
}

done_testing;
