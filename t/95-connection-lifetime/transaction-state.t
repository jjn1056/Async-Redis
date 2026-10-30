# t/95-connection-lifetime/transaction-state.t
#
# MULTI and WATCH are per-connection server state. When the connection
# ends, the server forgets them, so the client must too, and a transaction
# must never carry on, outside MULTI, on a connection made after the one it
# started on.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::AsyncAwait;
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

SKIP: {
    my $redis = skip_without_redis();

    subtest 'B7: transaction flags reset on a new connection' => sub {
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $r->connect };
        run { $r->watch('lt:k') };
        run { $r->multi_start };
        $r->disconnect;
        run { $r->connect };
        ok !$r->in_multi, 'not in MULTI';
        ok !$r->watching, 'not watching';
        ok !$r->is_dirty, 'not dirty';
        eval { $r->disconnect };
    };

    subtest 'B10: a transaction never commits writes after its connection drops' => sub {
        my $admin = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $admin->connect };
        run { $admin->del('lt:tx') };

        my $r = Async::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            reconnect       => 1,
            reconnect_delay => 0.01,
        );
        run { $r->connect };
        my $id = run { $r->client('ID') };

        run { $r->multi_start };
        run { $admin->client('KILL', 'ID', $id) };

        # A command that sees the drop, so the next one starts from a
        # known-dead connection.
        my $ping = $r->command('PING');
        settle($ping);

        my $set  = $r->command('SET', 'lt:tx', 'one');
        settle($set);
        my $exec = $r->exec;
        settle($exec);

        ok $exec->is_failed, 'EXEC fails';
        is run { $admin->get('lt:tx') }, undef, 'the queued write was not committed';
        eval { $r->disconnect };
        eval { $admin->disconnect };
    };

    my $admin = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    run { $admin->connect };

    sub reconnecting {
        Async::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            reconnect       => 1,
            reconnect_delay => 0.01,
            @_,
        );
    }

    # Kill $r's connection by the client id taken earlier (CLIENT ID would
    # be queued inside MULTI), and let one command notice.
    sub drop {
        my ($admin, $r, $id) = @_;
        run { $admin->client('KILL', 'ID', $id) };
        my $ping = $r->command('PING');
        settle($ping);
    }

    subtest 'B15: watch_multi never commits after its connection drops' => sub {
        my $r = reconnecting();
        run { $r->connect };
        run { $admin->set('lt:w', '0') };
        run { $admin->del('lt:out') };

        my $f = $r->watch_multi(['lt:w'], async sub {
            my ($tx) = @_;
            my $id = await $r->client('ID');
            await $admin->client('KILL', 'ID', $id);
            await $admin->set('lt:w', 'changed-by-other');
            eval { await $r->get('lt:other') };       # the drop is noticed here
            $tx->set('lt:out', 'committed');
        });
        is settle($f, 5), 'failed', 'watch_multi fails';
        is run { $admin->get('lt:out') }, undef, 'nothing was committed';
        eval { $r->disconnect };
    };

    subtest 'the pin is released by exec after a drop' => sub {
        my $r = reconnecting();
        run { $r->connect };
        my $id = run { $r->client('ID') };
        run { $r->multi_start };
        drop($admin, $r, $id);

        my $exec = $r->exec;
        is settle($exec), 'failed', 'EXEC fails';
        isa_ok failure_of($exec), 'Async::Redis::Error::Connection';
        ok !$r->in_multi, 'no longer in MULTI';
        ok !$r->is_dirty, 'not dirty';
        is run { $r->ping }, 'PONG', 'the next command reconnects';
        eval { $r->disconnect };
    };

    subtest 'unwatch after a drop releases the pin' => sub {
        my $r = reconnecting();
        run { $r->connect };
        my $id = run { $r->client('ID') };
        run { $r->watch('lt:k') };
        drop($admin, $r, $id);

        my $unwatch = $r->unwatch;
        is settle($unwatch), 'failed', 'UNWATCH fails on the dropped connection';
        isa_ok failure_of($unwatch), 'Async::Redis::Error::Connection';
        ok !$r->watching, 'no longer watching';
        ok !$r->is_dirty, 'not dirty';
        is run { $r->ping }, 'PONG', 'the next command reconnects';
        eval { $r->disconnect };
    };

    subtest 'EXECABORT ends the local transaction' => sub {
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $r->connect };
        run { $r->multi_start };
        my $bad = $r->command('SET', 'lt:only-one-arg');   # rejected at queue time
        is settle($bad), 'failed', 'the bad command is rejected';
        my $exec = $r->exec;
        is settle($exec), 'failed', 'EXEC fails';
        like '' . failure_of($exec), qr/EXECABORT/, 'with EXECABORT';
        ok !$r->in_multi, 'no longer in MULTI';
        ok !$r->is_dirty, 'not dirty';
        is settle($r->multi_start), 'done', 'a new MULTI starts';
        is settle($r->discard), 'done', 'and discards';
        eval { $r->disconnect };
    };

    subtest 'transactions with auto_pipeline' => sub {
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', auto_pipeline => 1);
        run { $r->connect };
        run { $r->del('lt:ap:n') };
        my $results = run { $r->multi(async sub {
            my ($tx) = @_;
            $tx->set('lt:ap:k', 'v');
            $tx->incr('lt:ap:n');
        }) };
        is $results, ['OK', 1], 'multi() runs';

        run { $admin->set('lt:ap:w', '0') };
        my $watched = run { $r->watch_multi(['lt:ap:w'], async sub {
            my ($tx) = @_;
            await $admin->set('lt:ap:w', 'changed');
            $tx->set('lt:ap:w2', 'y');
        }) };
        is $watched, undef, 'watch_multi aborts on a concurrent change';
        ok !$r->is_dirty, 'not dirty afterwards';
        eval { $r->disconnect };
    };

    eval { $admin->disconnect };
    cleanup_keys($redis, 'lt:*');
}

done_testing;
