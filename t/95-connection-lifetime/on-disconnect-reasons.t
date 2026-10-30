# t/95-connection-lifetime/on-disconnect-reasons.t
#
# on_disconnect's reason: 'client disconnect' for disconnect(); the
# stringified error for a stream failure; and nothing at all for a
# connection whose handshake failed, since it was never connected.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of inject_eof skip_without_redis);
use Future::IO;
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

sub client_recording {
    my ($reasons, %args) = @_;
    return Async::Redis->new(
        host          => $ENV{REDIS_HOST} // 'localhost',
        on_disconnect => sub { push @$reasons, $_[1] },
        %args,
    );
}

SKIP: {
    skip_without_redis();

    subtest 'disconnect' => sub {
        my @reasons;
        my $r = client_recording(\@reasons);
        run { $r->connect };
        $r->disconnect;
        is \@reasons, ['client disconnect'], 'reason is client disconnect';
    };

    subtest 'stream failure' => sub {
        my @reasons;
        my $r = client_recording(\@reasons);
        run { $r->connect };
        run { $r->del('lt:missing') };
        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        run { Future::IO->sleep(0.05) };
        inject_eof($r);
        is settle($blpop), 'failed', 'the waiting command fails';
        is scalar(@reasons), 1, 'on_disconnect fired once';
        is $reasons[0], '' . failure_of($blpop), 'with the error the command failed with';
        like $reasons[0], qr/Connection closed by peer/, 'the EOF error';
        eval { $r->disconnect };
    };

    subtest 'handshake failure' => sub {
        my @reasons;
        my $r = client_recording(\@reasons, database => 99999);
        my $c = $r->connect;
        is settle($c), 'failed', 'connect fails on SELECT';
        is \@reasons, [], 'on_disconnect never fires';
    };
}

done_testing;
