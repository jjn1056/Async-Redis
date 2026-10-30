# t/10-connection/handshake-order.t
#
# The handshake (AUTH, SELECT, CLIENT SETNAME) runs before anything else
# on a new connection. A command issued while it is still running must not
# be written between its commands: it waits for the connection, or fails
# if reconnect is off.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys
                          current_connection);
use IO::Socket::INET;
use Time::HiRes qw(time);
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

my %base = (host => $ENV{REDIS_HOST} // 'localhost');

# Record the command name of every write, for the duration of $code.
sub writes_during {
    my ($code) = @_;
    my @names;
    no warnings 'redefine';
    my $orig = \&Async::Redis::Connection::_send;
    local *Async::Redis::Connection::_send = sub {
        my (undef, $data) = @_;
        push @names, $1 while $data =~ /\*\d+\r\n\$\d+\r\n([^\r]+)\r\n/g;
        return $orig->(@_);
    };
    $code->();
    return \@names;
}

subtest 'a silent server times the handshake out' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $server = IO::Socket::INET->new(
        Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1,
    ) or die "listen: $!";
    my $r = Async::Redis->new(
        host            => '127.0.0.1',
        port            => $server->sockport,
        password        => 'x',
        connect_timeout => 0.3,
    );
    my $t0 = time;
    my $c  = $r->connect;
    is settle($c, 2), 'failed', 'connect fails';
    ok time - $t0 < 2, 'within the connect timeout, not hung';
    isa_ok failure_of($c), 'Async::Redis::Error::Timeout';
    ok !$r->is_connected, 'not connected';
    ok !current_connection($r), 'no current connection';
    is \@warnings, [], 'no warnings';
};

SKIP: {
    my $redis = skip_without_redis();

    subtest 'S1: a command issued during the handshake is written after it' => sub {
        my $r = Async::Redis->new(%base,
            database => 1, client_name => 'lt-s1', reconnect => 1);
        my ($c, $set);
        my $written = writes_during(sub {
            $c   = $r->connect;
            $set = $r->set('lt:s1', 1);      # no loop turn in between
            settle($_) for $c, $set;
        });
        is [settle($c), settle($set)], ['done', 'done'], 'both complete';
        is $written, ['SELECT', 'CLIENT', 'SET'], 'the command went out after the handshake';
        run { $r->del('lt:s1') };
        eval { $r->disconnect };
    };

    subtest 'S1: with reconnect off it fails Not connected' => sub {
        my $r = Async::Redis->new(%base,
            database => 1, client_name => 'lt-s1', reconnect => 0);
        my ($c, $set);
        my $written = writes_during(sub {
            $c   = $r->connect;
            $set = $r->set('lt:s1', 1);
            settle($_) for $c, $set;
        });
        is settle($c), 'done', 'connect completes';
        is settle($set), 'failed', 'the command fails';
        isa_ok failure_of($set), 'Async::Redis::Error::Disconnected';
        like '' . failure_of($set), qr/Not connected/, 'Not connected';
        is $written, ['SELECT', 'CLIENT'], 'only the handshake was written';
        eval { $r->disconnect };
    };

    subtest 'handshake replies are not mistaken for command replies' => sub {
        my $r = Async::Redis->new(%base, database => 1, client_name => 'lt-s1');
        run { $r->connect };
        like run { $r->client('INFO') }, qr/\bdb=1\b/, 'the connection is on db 1';
        like run { $r->client('INFO') }, qr/\bname=lt-s1\b/, 'with its client name';
        eval { $r->disconnect };
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
