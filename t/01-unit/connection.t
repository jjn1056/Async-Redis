# t/01-unit/connection.t
#
# Async::Redis::Connection on a socketpair, no Redis. The test holds the
# other end ($peer) and plays the server.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of);
use Future;
use Future::IO;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Scalar::Util qw(refaddr);
use Time::HiRes ();
use Async::Redis;
use Async::Redis::Error::Disconnected;

$SIG{PIPE} = 'IGNORE';

my $PING = "*1\r\n\$4\r\nPING\r\n";

# ($client, $conn, $peer, $mine). The caller keeps $mine alive, standing in
# for a parent process's copy of the socket in the fork cases.
sub pair {
    socketpair(my $mine, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    $mine->blocking(0);
    $peer->blocking(0);
    my $client = Async::Redis->new(host => 'localhost');
    my $conn   = Async::Redis::Connection->new(client => $client, socket => $mine);
    return ($client, $conn, $peer, $mine);
}

sub entry {
    return {
        future      => Future->new,
        cmd         => 'PING',
        args        => [],
        deadline    => Time::HiRes::time() + 5,
        redis_error => 'fail',
    };
}

sub disconnected { Async::Redis::Error::Disconnected->new(message => $_[0] // 'test close') }

# Everything the peer receives within $secs, and whether it saw EOF.
sub peer_reads {
    my ($peer, $secs) = @_;
    my $until = Time::HiRes::time() + ($secs // 0.5);
    my ($data, $eof) = ('', 0);
    while (Time::HiRes::time() < $until) {
        my $n = sysread($peer, my $buf, 65536);
        if (defined $n && $n == 0) { $eof = 1; last }
        $data .= $buf if $n;
        run { Future::IO->sleep(0.01) };
    }
    return ($data, $eof);
}

# Fill the socket's send buffer so the next write stays pending.
sub fill_send_buffer {
    my ($mine) = @_;
    my $chunk = 'x' x 65536;
    1 while defined syswrite($mine, $chunk);
}

subtest 'submit then reply resolves the entry' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my $e = entry();
    is settle($conn->submit($PING, [$e])), 'done', 'submit completes after the write';
    syswrite($peer, "+PONG\r\n");
    is settle($e->{future}), 'done', 'entry resolves';
    is $e->{future}->get, 'PONG', 'with the reply';
    $conn->close(disconnected());
};

subtest 'replies resolve entries in order' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my ($e1, $e2) = (entry(), entry());
    is settle($conn->submit($PING . $PING, [$e1, $e2])), 'done', 'submitted';
    syswrite($peer, "+one\r\n+two\r\n");
    is settle($e2->{future}), 'done', 'second entry resolves';
    is $e1->{future}->get, 'one', 'first entry gets the first reply';
    is $e2->{future}->get, 'two', 'second entry gets the second reply';
    $conn->close(disconnected());
};

subtest 'two submits write and resolve in order' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my ($e1, $e2) = (entry(), entry());
    my $s1 = $conn->submit("*1\r\n\$4\r\nECHO\r\n", [$e1]);
    my $s2 = $conn->submit($PING, [$e2]);
    is settle($s2), 'done', 'second submit completes';
    is settle($s1), 'done', 'first submit completes';
    my ($data) = peer_reads($peer, 0.1);
    is $data, "*1\r\n\$4\r\nECHO\r\n$PING", 'the peer received them in submit order';
    syswrite($peer, "+one\r\n+two\r\n");
    is settle($e2->{future}), 'done', 'second entry resolves';
    is [$e1->{future}->get, $e2->{future}->get], ['one', 'two'], 'replies matched in order';
    $conn->close(disconnected());
};

subtest 'a second submit waits for the first write to finish' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my $ECHO = "*1\r\n\$4\r\nECHO\r\n";
    fill_send_buffer($mine);
    my $first  = $conn->submit($ECHO, [entry()]);
    my $second = $conn->submit($PING, [entry()]);
    ok !$first->is_ready, 'the first write is pending';
    ok !$second->is_ready, 'the second submit waits';

    my $data  = '';
    my $until = Time::HiRes::time() + 2;
    until ($second->is_ready || Time::HiRes::time() > $until) {
        my $n = sysread($peer, my $buf, 65536);
        $data .= $buf if $n;
        run { Future::IO->sleep(0.001) };
    }
    $data .= (peer_reads($peer, 0.05))[0];
    is [settle($first), settle($second)], ['done', 'done'], 'both writes complete';
    like $data, qr/\Q$ECHO$PING\E\z/, 'the second was written after the first, whole';
    $conn->close(disconnected());
};

subtest 'close fails pending entries with the close error' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my $e = entry();
    settle($conn->submit($PING, [$e]));
    my $err = disconnected();
    $conn->close($err);
    ok $e->{future}->is_failed, 'entry failed';
    is refaddr(failure_of($e->{future})), refaddr($err), 'with the close error itself';
    ok $conn->is_closed, 'connection is closed';
    is refaddr($conn->close_error), refaddr($err), 'close_error is the close error';
};

subtest 'close during a pending write fails submit with the close error' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    fill_send_buffer($mine);
    my $s   = $conn->submit($PING, [entry()]);
    ok !$s->is_ready, 'the write is pending';
    my $err = disconnected();
    $conn->close($err);
    ok $s->is_failed, 'submit failed, not cancelled';
    is refaddr(failure_of($s)), refaddr($err), 'with the close error itself';
};

subtest 'a submitter waiting on the gate unwinds with the close error' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    fill_send_buffer($mine);
    my $holder = $conn->submit($PING, [entry()]);
    my $queued = $conn->submit($PING, [entry()]);
    ok !$queued->is_ready, 'the second submit waits for the gate';
    my $err = disconnected();
    $conn->close($err);
    is refaddr(failure_of($holder)), refaddr($err), 'the holder fails with the close error';
    is refaddr(failure_of($queued)), refaddr($err), 'the waiter fails with the close error';
};

subtest 'submit after close fails with the close error' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my $err = disconnected();
    $conn->close($err);
    my $e = entry();
    my $s = $conn->submit($PING, [$e]);
    ok $s->is_failed, 'submit fails';
    is refaddr(failure_of($s)), refaddr($err), 'with the close error';
    ok !$e->{future}->is_ready, 'the entry was never registered';
    my ($data) = peer_reads($peer, 0.05);
    is $data, '', 'nothing was written';
};

subtest 'close cancels the pending read before shutdown' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    settle($conn->submit($PING, [entry()]));
    my $read_f = $conn->{read_f};
    ok $read_f && !$read_f->is_ready, 'the reader is waiting on a read';
    $conn->close(disconnected());
    ok $read_f->is_cancelled, 'the read was cancelled';
    my (undef, $eof) = peer_reads($peer);
    ok $eof, 'the peer sees EOF';
};

subtest 'close ends the reader' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    settle($conn->submit($PING, [entry()]));
    my $reader = $conn->{reader};
    ok $reader && !$reader->is_ready, 'the reader is waiting';
    $conn->close(disconnected());
    ok $reader->is_ready, 'the reader has ended, not left parked on its deadline';
};

subtest 'close is idempotent and never throws' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my ($first, $second) = (disconnected('first'), disconnected('second'));
    ok lives { $conn->close($first) }, 'first close';
    ok lives { $conn->close($second) }, 'second close';
    is refaddr($conn->close_error), refaddr($first), 'the first close error stands';
};

subtest 'reader failure closes the connection and reports to the client once' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my @calls;
    no warnings 'redefine';
    local *Async::Redis::_connection_lost = sub { push @calls, [ @_[1, 2] ] };

    my ($client, $conn, $peer, $mine) = pair();
    my $e = entry();
    settle($conn->submit($PING, [$e]));
    my $reader = $conn->{reader};
    ok $reader, 'a reader is running';
    shutdown($peer, 2);
    is settle($reader), 'done', 'the reader ends';
    ok !$reader->is_cancelled, 'it was not cancelled';

    is scalar(@calls), 1, 'the client is told once';
    is refaddr($calls[0][0]), refaddr($conn), 'about this connection';
    isa_ok $calls[0][1], 'Async::Redis::Error::Connection';
    like "$calls[0][1]", qr/closed by peer/, 'with the EOF error';
    ok $conn->is_closed, 'the connection is closed';
    is refaddr(failure_of($e->{future})), refaddr($calls[0][1]), 'the entry fails with that error';
    is \@warnings, [], 'no warnings';
};

subtest 'close in another pid drops references only' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    my $e = entry();
    settle($conn->submit($PING, [$e]));
    my $read_f = $conn->{read_f};
    my $reader = $conn->{reader};
    $conn->{pid} = $$ + 99999;
    $conn->close(disconnected());
    ok !$read_f->is_cancelled, 'the read was not cancelled';
    ok !$e->{future}->is_ready, 'the entry was not failed';
    my (undef, $eof) = peer_reads($peer, 0.1);
    ok !$eof, 'the peer sees no EOF';
    $reader->cancel;
    $read_f->cancel;
};

subtest 'DESTROY in another pid does not shut the socket down' => sub {
    my ($client, $conn, $peer, $mine) = pair();
    $conn->{pid} = $$ + 99999;
    undef $conn;
    my (undef, $eof) = peer_reads($peer, 0.1);
    ok !$eof, 'the peer sees no EOF';
};

done_testing;
