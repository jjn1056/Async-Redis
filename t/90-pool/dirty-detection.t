# t/90-pool/dirty-detection.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis';
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis::Pool;
use Future::IO;
use Future;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        run { $r->connect };
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'is_dirty detects in_multi' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        ok(!$conn->is_dirty, 'connection starts clean');

        # Start MULTI
        run { $conn->multi_start };
        ok($conn->in_multi, 'in_multi flag set');
        ok($conn->is_dirty, 'connection is dirty');

        # Don't EXEC/DISCARD - release dirty
        $pool->release($conn);

        # Should be destroyed
        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects watching' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        run { $conn->watch('dirty:key') };

        ok($conn->watching, 'watching flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects in_pubsub' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        run { $conn->subscribe('dirty:channel') };

        ok($conn->in_pubsub, 'in_pubsub flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty pubsub connection destroyed');
    };

    subtest 'clean connection reused' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn1 = run { $pool->acquire };
        my $id1 = "$conn1";
        run { $conn1->ping };  # Normal command
        ok(!$conn1->is_dirty, 'connection still clean');
        $pool->release($conn1);

        my $conn2 = run { $pool->acquire };
        my $id2 = "$conn2";

        is($id1, $id2, 'clean connection was reused');

        $pool->release($conn2);
    };

    subtest 'properly completed transaction is clean' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        run { $conn->multi_start };
        ok($conn->in_multi, 'in transaction');

        run { $conn->command('INCR', 'dirty:counter') };
        run { $conn->exec };

        ok(!$conn->in_multi, 'transaction completed');
        ok(!$conn->is_dirty, 'connection is clean');

        my $id = "$conn";
        $pool->release($conn);

        my $conn2 = run { $pool->acquire };
        is("$conn2", $id, 'connection reused after clean transaction');

        $pool->release($conn2);
        await_f($pool->with(async sub {
            my ($r) = @_;
            await $r->del('dirty:counter');
        }));
    };

    subtest 'discard clears in_multi' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        run { $conn->multi_start };
        ok($conn->in_multi, 'in transaction');

        run { $conn->discard };
        ok(!$conn->in_multi, 'DISCARD cleared in_multi');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };

    subtest 'unwatch clears watching' => sub {
        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = run { $pool->acquire };
        run { $conn->watch('dirty:key') };
        ok($conn->watching, 'watching');

        run { $conn->unwatch };
        ok(!$conn->watching, 'UNWATCH cleared watching');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };

    subtest 'cleanup mode discards a transaction and keeps the client' => sub {
        my $pool = Async::Redis::Pool->new(
            host     => $ENV{REDIS_HOST} // 'localhost',
            on_dirty => 'cleanup',
        );

        my $conn = run { $pool->acquire };
        run { $conn->multi_start };
        $pool->release($conn);
        run { Future::IO->sleep(0.2) };     # cleanup runs asynchronously

        is($pool->stats->{destroyed}, 0, 'nothing destroyed');
        my $again = run { $pool->acquire };
        ref_is($again, $conn, 'the same client comes back');
        ok(!$again->in_multi, 'not in MULTI');
        is(run { $again->ping }, 'PONG', 'and usable');
        $pool->release($again);
    };

    subtest 'pool discards a client whose transaction connection dropped' => sub {
        for my $mode (qw(destroy cleanup)) {
            my $pool = Async::Redis::Pool->new(
                host     => $ENV{REDIS_HOST} // 'localhost',
                on_dirty => $mode,
            );
            my $admin = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
            run { $admin->connect };

            my $conn = run { $pool->acquire };
            my $id   = run { $conn->client('ID') };
            run { $conn->multi_start };
            run { $admin->client('KILL', 'ID', $id) };
            eval { run { $conn->ping } };    # notices the drop
            $pool->release($conn);
            run { Future::IO->sleep(0.2) };

            is($pool->stats->{destroyed}, 1, "$mode: the client is destroyed");
            my $next = run { $pool->acquire };
            ok(!$next->in_multi, "$mode: the next client is not in MULTI");
            is(run { $next->ping }, 'PONG', "$mode: and usable");
            $pool->release($next);
            $admin->disconnect;
        }
    };
}

done_testing;
