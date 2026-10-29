# t/95-connection-lifetime/disconnect-cancels-reconnect.t
#
# A user disconnect() must stop a reconnect that is already running, so the
# client does not come back up on its own after a deliberate disconnect.

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
        subtest 'B2: disconnect cancels a reconnect in progress' => sub {
            my $connects = 0;
            my $r = Async::Redis->new(
                host            => $ENV{REDIS_HOST} // 'localhost',
                reconnect       => 1,
                reconnect_delay => 0.05,
                on_connect      => sub { $connects++ },
            );
            run { $r->connect };
            run { $r->ping };
            $r->disconnect;

            # With reconnect enabled this command starts a reconnect.
            my $set = $r->command('SET', 'lt:b', 'b');
            $r->disconnect;

            is settle($set), 'failed', 'the command fails';
            isa_ok failure_of($set), 'Async::Redis::Error::Disconnected';
            ok !$r->is_connected, 'client stays disconnected';
            is $connects, 1, 'no connection was made after disconnect()';
            eval { $r->disconnect };
        };
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
