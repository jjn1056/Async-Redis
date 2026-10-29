use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(fake_connection current_connection);
use Scalar::Util qw(blessed refaddr);
use Future::AsyncAwait;
use Future::IO;
use Async::Redis;

# A connection that fails closes itself and reports to its client once,
# through _connection_lost. These pin what the client does with that.

sub conn_error {
    Async::Redis::Error::Connection->new(message => $_[0], host => 'x', port => 1);
}

subtest 'detached inflight futures fail with typed error, not generic cancellation' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my ($conn, $peer) = fake_connection($c);
    my $f1 = Future->new;
    my $f2 = Future->new;
    push @{$conn->{inflight}},
        { future => $f1, cmd => 'GET', args => ['x'], deadline => 0 },
        { future => $f2, cmd => 'SET', args => ['y', 'z'], deadline => 0 };

    my $err = Async::Redis::Error::Timeout->new(
        message => 'test timeout',
        timeout => 5,
    );
    $conn->_fail($err);

    ok $f1->is_failed, 'f1 failed';
    is refaddr(($f1->failure)[0]), refaddr($err),
        'f1 carries the typed error, not cancellation';

    ok $f2->is_failed, 'f2 failed';
    is refaddr(($f2->failure)[0]), refaddr($err),
        'f2 also carries the typed error';

    is $conn->inflight_count, 0, 'inflight drained';
    ok !current_connection($c), 'the client holds no connection';
    is $c->is_connected, 0, 'connected cleared';
};

subtest 'reentrance during same call is a no-op (idempotence guard)' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my ($conn, $peer) = fake_connection($c);
    my $on_disc_calls = 0;

    # A callback that reports the same loss again while it is being
    # handled. The connection is no longer current, so nothing happens.
    $c->{on_disconnect} = sub {
        $on_disc_calls++;
        $c->_connection_lost($conn, conn_error('reentrant'));
    };

    $conn->_fail(conn_error('first'));

    is $on_disc_calls, 1, 'on_disconnect fired exactly once';
};

subtest 'second fatal after first completes is a fresh transition' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my $on_disc_calls = 0;
    $c->{on_disconnect} = sub { $on_disc_calls++ };

    my ($first, $peer1) = fake_connection($c);
    $first->_fail(conn_error('first'));

    # A later connection fails too: a NEW transition.
    my ($second, $peer2) = fake_connection($c);
    $second->_fail(conn_error('second'));

    is $on_disc_calls, 2, 'on_disconnect fired twice (once per transition)';
};

subtest 'a connection that is no longer current is ignored' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my $on_disc_calls = 0;
    $c->{on_disconnect} = sub { $on_disc_calls++ };

    my ($old, $peer1) = fake_connection($c);
    my ($new, $peer2) = fake_connection($c);
    $c->_connection_lost($old, conn_error('late report from the old connection'));

    is refaddr(current_connection($c)), refaddr($new), 'the current connection is kept';
    is $c->is_connected, 1, 'still connected';
    is $on_disc_calls, 0, 'on_disconnect not fired';
};

subtest 'on_disconnect skipped when not previously connected' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my ($conn, $peer) = fake_connection($c, connected => 0);   # e.g., during handshake
    my $on_disc_calls = 0;
    $c->{on_disconnect} = sub { $on_disc_calls++ };

    $conn->_fail(conn_error('handshake failed'));

    is $on_disc_calls, 0, 'on_disconnect not fired for pre-connected fatal';
};

subtest 'auto-pipeline queued futures also fail with typed error' => sub {
    require Async::Redis::AutoPipeline;
    my $c = Async::Redis->new(host => 'x', port => 1);
    my ($conn, $peer) = fake_connection($c);

    my $ap = Async::Redis::AutoPipeline->new(
        redis      => $c,
        connection => $conn,
        max_depth  => 10,
    );
    $conn->{auto_pipeline} = $ap;

    # Queued but not yet flushed.
    my $future = Future->new;
    push @{$ap->{_queue}}, { cmd => ['GET', 'k'], future => $future };

    my $err = conn_error('boom');
    $conn->_fail($err);

    ok $future->is_failed, 'queued auto-pipeline future failed';
    is refaddr(($future->failure)[0]), refaddr($err), 'carries the typed error';
    is scalar @{$ap->{_queue}}, 0, 'queue drained';
};

subtest 'a dying on_disconnect does not wedge the next connection' => sub {
    my $c = Async::Redis->new(host => 'x', port => 1);
    my $on_disc_calls = 0;
    $c->{on_disconnect} = sub { $on_disc_calls++; die "intentional test failure\n" };

    my ($first, $peer1) = fake_connection($c);
    my $died = dies { $first->_fail(conn_error('x')) };
    like $died, qr/intentional test failure/, 'rethrew the callback exception';
    ok $first->is_closed, 'the connection closed anyway';

    my ($second, $peer2) = fake_connection($c);
    like dies { $second->_fail(conn_error('y')) }, qr/intentional test failure/,
        'the later failure rethrows too';
    is $on_disc_calls, 2, 'a later connection\'s failure still fires on_disconnect';
};

done_testing;
