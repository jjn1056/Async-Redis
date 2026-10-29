# t/95-connection-lifetime/stale-reader.t
#
# A reader started on one connection must not act on a later one. After a
# disconnect, the old reader's deadline must not fire a timeout against the
# reconnected socket.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::IO;
use Async::Redis;
use Time::HiRes qw(time);

$SIG{PIPE} = 'IGNORE';

SKIP: {
    my $redis = skip_without_redis();

    subtest 'B1: an old reader cannot fail a new connection' => sub {
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $r->connect };
        run { $r->del('lt:missing') };

        # BLPOP with a 1s server timeout gets a client deadline of
        # 1s + blocking_timeout_buffer (2s) = 3s from now.
        my $t0    = time;
        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        run { Future::IO->sleep(0.1) };
        $r->disconnect;
        is settle($blpop), 'failed', 'BLPOP fails on disconnect';

        run { $r->connect };
        my $wait = 3.5 - (time - $t0);
        run { Future::IO->sleep($wait) } if $wait > 0;

        ok $r->is_connected, 'still connected after the old deadline passed';
        my $get = $r->get('lt:missing');
        is settle($get), 'done', 'GET on the new connection succeeds';
        note 'GET failed with: ' . failure_of($get) if $get->is_failed;
        eval { $r->disconnect };
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
