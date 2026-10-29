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
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

SKIP: {
    my $redis = skip_without_redis();

    todo 'connection lifetime (Plan B)' => sub {
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
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
