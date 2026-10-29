# t/95-connection-lifetime/submit-path.t
#
# Every submit path obtains one current connection and does all its work
# on it. While the connection is down, waiters share one reconnect, and
# their writes go out in the order they were issued.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of inject_eof skip_without_redis cleanup_keys);
use Future::IO;
use Scalar::Util qw(refaddr);
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

my %base = (host => $ENV{REDIS_HOST} // 'localhost');

# Kill $r's connection from the server side, and let one command notice.
sub drop_connection {
    my ($admin, $r) = @_;
    my $id = run { $r->client('ID') };
    run { $admin->client('KILL', 'ID', $id) };
    my $ping = $r->command('PING');
    is settle($ping), 'failed', 'a command notices the drop';
}

SKIP: {
    my $redis = skip_without_redis();
    my $admin = Async::Redis->new(%base);
    run { $admin->connect };

    subtest 'one reconnect for many waiters' => sub {
        my $connects = 0;
        my $r = Async::Redis->new(%base,
            reconnect       => 1,
            reconnect_delay => 0.01,
            on_connect      => sub { $connects++ },
        );
        run { $r->connect };
        drop_connection($admin, $r);

        my @written;
        no warnings 'redefine';
        my $orig = \&Async::Redis::Connection::_send;
        local *Async::Redis::Connection::_send = sub {
            my (undef, $data) = @_;
            push @written, $1 while $data =~ /lt:sp:(\d)/g;
            return $orig->(@_);
        };

        my @sets = map { $r->command('SET', "lt:sp:$_", $_) } 1 .. 5;
        is [map { settle($_) } @sets], [('done') x 5], 'every waiter succeeds';
        is $connects, 2, 'one reconnect in total';
        is \@written, [1 .. 5], 'written in the order they were issued';
        eval { $r->disconnect };
    };

    subtest 'auto-pipeline across a drop' => sub {
        my $r = Async::Redis->new(%base,
            auto_pipeline   => 1,
            reconnect       => 1,
            reconnect_delay => 0.01,
        );
        run { $r->connect };
        run { $r->set("lt:ap:$_", "v$_") } for 1 .. 3;
        drop_connection($admin, $r);

        my @gets = map { $r->get("lt:ap:$_") } 1 .. 3;
        is [map { settle($_) } @gets], [('done') x 3], 'reconnect on: all succeed';
        is [map { $_->get } @gets], [qw(v1 v2 v3)], 'in order';
        eval { $r->disconnect };

        my $off = Async::Redis->new(%base, auto_pipeline => 1, reconnect => 0);
        run { $off->connect };
        drop_connection($admin, $off);
        my @failed = map { $off->get("lt:ap:$_") } 1 .. 3;
        is [map { settle($_) } @failed], [('failed') x 3], 'reconnect off: all fail';
        for my $f (@failed) {
            my $err = failure_of($f);
            isa_ok $err, 'Async::Redis::Error::Disconnected';
            like "$err", qr/Not connected/, 'Not connected';
        }
        eval { $off->disconnect };
    };

    subtest 'concurrent connects share one attempt' => sub {
        my $connects = 0;
        my $r = Async::Redis->new(%base, on_connect => sub { $connects++ });
        my $c1 = $r->connect;
        my $c2 = $r->connect;
        is [settle($c1), settle($c2)], ['done', 'done'], 'both connects succeed';
        is $connects, 1, 'one connection was made';
        is refaddr($c1->get), refaddr($r), 'the first resolves to the client';
        is refaddr($c2->get), refaddr($r), 'the second resolves to the client';
        eval { $r->disconnect };
    };

    subtest 'disconnect aborts a connect in progress' => sub {
        my $connects = 0;
        my $r = Async::Redis->new(%base, on_connect => sub { $connects++ });
        my $c = $r->connect;
        $r->disconnect;                     # no loop turn in between
        is settle($c), 'failed', 'the connect fails';
        isa_ok failure_of($c), 'Async::Redis::Error::Disconnected';
        run { Future::IO->sleep(0.1) };     # time for a stray attempt to finish
        ok !$r->is_connected, 'the client stays disconnected';
        is $connects, 0, 'on_connect never fired';
        eval { $r->disconnect };
    };

    # A failed command's continuation runs while the connection is being
    # torn down. By then the client must already be disconnected, so that
    # a retry or a connect from there makes a new connection.
    subtest 'a retry from a failed command\'s continuation reconnects' => sub {
        my $r = Async::Redis->new(%base, reconnect => 1, reconnect_delay => 0.01);
        run { $r->connect };
        run { $r->set('lt:sp:retry', 'v') };
        run { $r->del('lt:missing') };

        my ($seen_connected, $retry);
        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        $blpop->on_fail(sub {
            $seen_connected = $r->is_connected;
            $retry          = $r->get('lt:sp:retry');
        });
        run { Future::IO->sleep(0.05) };
        inject_eof($r);

        is settle($blpop), 'failed', 'the command fails with the connection';
        is $seen_connected, 0, 'the client is already disconnected in the continuation';
        is settle($retry), 'done', 'the retry succeeds'
            or diag 'retry failed with: ' . failure_of($retry);
        is $retry->get, 'v', 'on a new connection' if $retry->is_done;
        eval { $r->disconnect };
    };

    subtest 'connect from a failure callback makes a new connection' => sub {
        my $r = Async::Redis->new(%base, reconnect => 0);
        run { $r->connect };
        run { $r->del('lt:missing') };

        my $reconnect;
        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        $blpop->on_fail(sub { $reconnect = $r->connect });
        run { Future::IO->sleep(0.05) };
        inject_eof($r);

        is settle($blpop), 'failed', 'the command fails with the connection';
        is settle($reconnect), 'done', 'connect completes';
        ok $r->is_connected, 'the client is connected again';
        my $ping = $r->command('PING');
        is settle($ping), 'done', 'and usable';
        eval { $r->disconnect };
    };

    eval { $admin->disconnect };
    cleanup_keys($redis, 'lt:*');
}

done_testing;
