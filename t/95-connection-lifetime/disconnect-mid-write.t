# t/95-connection-lifetime/disconnect-mid-write.t
#
# disconnect() promises callers a Disconnected error so they can tell "I
# disconnected" from "the server dropped me". That must hold for a command
# whose write has not finished when disconnect() runs, and such a command
# must be settled by disconnect itself rather than resuming later.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::IO;
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

sub new_client { Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost') }

SKIP: {
    my $redis = skip_without_redis();

    subtest 'B5: disconnect mid-write reports Disconnected' => sub {
        my $r = new_client();
        run { $r->connect };
        run { $r->del('lt:missing') };
        my $f = $r->command('BLPOP', 'lt:missing', '10');
        $r->disconnect;                       # no loop turn in between
        is settle($f), 'failed', 'the command fails';
        my $err = failure_of($f);
        isa_ok $err, 'Async::Redis::Error::Disconnected';
        like "" . ($err // ''), qr/Client disconnect/, 'with the client-disconnect message';
        eval { $r->disconnect };
    };

    subtest "B6: dropping a mid-write command's future warns nothing" => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $r = new_client();
        run { $r->connect };
        run { $r->del('lt:missing') };
        {
            my $dropped = $r->command('BLPOP', 'lt:missing', '10');
            $r->disconnect;
        }
        run { $r->connect };
        my $ping = $r->command('PING');
        settle($ping);
        run { Future::IO->sleep(0.1) };
        is \@warnings, [], 'no warnings';
        eval { $r->disconnect };
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
