# t/10-connection/fork-read-future.t
#
# A forked child inherits the parent's connection, including a read that
# is in progress. The child must drop that connection without touching it:
# cancelling the read or shutting the socket down would act on the
# parent's connection. A later disconnect in the child must not reach it
# either.

use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis qw(fake_connection current_connection run);
use Test2::V0;
use Future::IO;
use Time::HiRes ();
use Async::Redis;

# A client mid-read on a connection made by "another process". $mine is
# kept alive here, standing in for the parent's copy of the socket.
sub forked_client {
    my $c = Async::Redis->new(host => 'localhost');
    my ($conn, $peer) = fake_connection($c);
    run { $conn->submit("*1\r\n\$4\r\nPING\r\n", [{
        future   => Future->new,
        cmd      => 'PING',
        args     => [],
        deadline => Time::HiRes::time() + 5,
    }]) };
    my %s = (
        client => $c, conn => $conn, peer => $peer,
        mine   => $conn->socket,
        read_f => $conn->{read_f},
        reader => $conn->{reader},
    );
    $conn->{pid} = $$ + 99999;
    return \%s;
}

sub peer_sees_eof {
    my ($peer) = @_;
    my $until = Time::HiRes::time() + 0.1;
    while (Time::HiRes::time() < $until) {
        my $n = sysread($peer, my $buf, 65536);
        return 1 if defined $n && $n == 0;
        run { Future::IO->sleep(0.01) };
    }
    return 0;
}

sub stop {
    my ($s) = @_;
    $s->{reader}->cancel;
    $s->{read_f}->cancel;
}

subtest '_check_fork drops the parent\'s connection' => sub {
    my $s = forked_client();
    ok $s->{read_f} && !$s->{read_f}->is_ready, 'a read is in progress';

    ok $s->{client}->_check_fork, '_check_fork detected the fork';
    ok !current_connection($s->{client}), 'the client holds no connection';
    is $s->{client}->is_connected, 0, 'connected is false after fork';
    ok !peer_sees_eof($s->{peer}), 'the parent\'s socket was not shut down';
    stop($s);
};

subtest 'disconnect after fork with stale read future' => sub {
    my $s = forked_client();
    $s->{client}->_check_fork;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    ok lives { $s->{client}->disconnect }, 'disconnect after fork does not die';
    ok !$s->{read_f}->is_cancelled, 'disconnect did not cancel the parent\'s read';
    ok !peer_sees_eof($s->{peer}), 'nor shut the parent\'s socket down';
    is \@warnings, [], 'no warnings';
    stop($s);
};

subtest 'stale future not cancelled after fork' => sub {
    my $s = forked_client();
    $s->{client}->_check_fork;
    ok !$s->{read_f}->is_cancelled,
        'the read is not cancelled (it belongs to the parent)';
    ok !$s->{reader}->is_ready, 'nor is the parent\'s reader';
    stop($s);
};

done_testing;
