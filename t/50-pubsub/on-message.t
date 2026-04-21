# t/50-pubsub/on-message.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis';
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;

sub _make_publisher {
    my $r = Async::Redis->new(
        host => $ENV{REDIS_HOST} // 'localhost',
        connect_timeout => 2,
    );
    run { $r->connect };
    return $r;
}

sub _make_subscriber {
    my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    run { $r->connect };
    return $r;
}

# Each callback-mode subtest MUST use its own subscriber connection.
# Reusing a subscriber across subtests races: once on_message is set
# and the driver is running, a subsequent $subscriber->subscribe call's
# internal confirmation-read competes with the driver's frame-read.
sub _with_redis (&) {
    my ($code) = @_;
    my $publisher = eval { _make_publisher() };
    unless ($publisher) {
        skip "Redis not available: $@", 1;
        return;
    }
    $code->($publisher);
    $publisher->disconnect;
}

# --- Unit tests (no Redis needed) ---

subtest 'on_message accessor — set and get' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    is($sub->on_message, undef, 'no callback by default');

    my $cb = sub { 1 };
    $sub->on_message($cb);
    is($sub->on_message, $cb, 'accessor returns the set callback');
};

subtest 'on_error accessor — set and get' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    is($sub->on_error, undef, 'no callback by default');

    my $cb = sub { 1 };
    $sub->on_error($cb);
    is($sub->on_error, $cb, 'accessor returns the set callback');
};

subtest 'next() croaks once on_message is set (sticky mode)' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);
    $sub->on_message(sub { });

    # `async sub` traps exceptions onto the returned Future; ->get
    # re-throws them synchronously so we can assert on $@.
    my $err;
    eval { $sub->next->get; };
    $err = $@;
    ok($err, 'next() throws');
    like($err, qr/callback-driven/i, 'error mentions callback-driven');
};

subtest '_invoke_user_callback returns callback result for sync callback' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);
    $sub->on_message(sub { 'ignored' });

    my $msg = { type => 'message', channel => 'x', pattern => undef, data => 'y' };
    my $cb = $sub->on_message;
    my $result = $sub->_invoke_user_callback($cb, $msg);
    is($result, 'ignored', 'returns callback result');
};

subtest '_invoke_user_callback routes die to on_error' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my $err_seen;
    $sub->on_error(sub {
        my ($s, $err) = @_;
        $err_seen = $err;
    });

    my $cb = sub { die "boom\n" };
    $sub->_invoke_user_callback($cb, { type => 'message' });
    like($err_seen, qr/boom/, 'on_error received the exception');
    ok($sub->is_closed, 'subscription closed after fatal error');
};

subtest '_handle_fatal_error dies when no on_error set' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my $err;
    eval { $sub->_handle_fatal_error("loud failure\n"); };
    $err = $@;
    like($err, qr/loud failure/, 'die propagates when no on_error registered');
    ok($sub->is_closed, 'subscription closed');
};

subtest '_handle_fatal_error fires on_error with subscription as first arg' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my @args_seen;
    $sub->on_error(sub { @args_seen = @_ });

    $sub->_handle_fatal_error("oops\n");
    is(scalar @args_seen, 2, 'on_error called with two args');
    is($args_seen[0], $sub, 'first arg is subscription');
    like($args_seen[1], qr/oops/, 'second arg is error');
};

subtest '_dispatch_frame routes to on_message when set' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my $seen;
    $sub->on_message(sub { $seen = $_[1]; 'cb-return' });

    my $frame = [ 'message', 'chan', 'payload' ];
    my $result = $sub->_dispatch_frame($frame);

    is($seen->{type},    'message', 'callback received type');
    is($seen->{channel}, 'chan',    'callback received channel');
    is($seen->{data},    'payload', 'callback received data');
    is($seen->{pattern}, undef,     'pattern is undef on non-pmessage');
    is($result,          'cb-return', 'dispatch returns callback result');
};

subtest '_dispatch_frame returns Future when callback returns Future (backpressure signal)' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my $gate = Future->new;
    $sub->on_message(sub { $gate });

    my $frame = [ 'message', 'chan', 'payload' ];
    my $result = $sub->_dispatch_frame($frame);

    ok(Scalar::Util::blessed($result) && $result->isa('Future'),
        '_dispatch_frame returns callback Future through _invoke_user_callback');
    is($result, $gate, 'returned Future is the one the callback returned');
    ok(!$result->is_ready, 'Future is still pending');
};

subtest '_dispatch_frame falls through to _deliver_message when no callback' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    my $frame = [ 'message', 'chan', 'payload' ];
    my $result = $sub->_dispatch_frame($frame);

    # With no callback, the message is buffered for next() consumers
    is(scalar @{$sub->{_message_queue}}, 1, 'message buffered in queue');
    is($sub->{_message_queue}[0]{data}, 'payload', 'buffered message data');
    is($result, undef, 'dispatch returns undef on fallthrough');
};

# --- Integration tests (need Redis) ---

SKIP: {
    _with_redis {
        my ($publisher) = @_;

        # Integration tests bypass the run{} helper's busy-poll pump
        # because it interacts badly with the driver's on_done
        # callbacks (pumping via Future::IO->sleep(0)->get corrupts
        # internal state when the driver fires a failed-Future →
        # on_error → _close sequence). Direct ->get works reliably.

        subtest 'on_message receives messages published to subscribed channels' => sub {
            my $subscriber = _make_subscriber();
            my @received;
            my $sub = $subscriber->subscribe('test:onmsg:basic')->get;
            $sub->on_message(sub {
                my ($s, $msg) = @_;
                push @received, $msg;
            });

            for my $i (1..3) {
                $publisher->publish('test:onmsg:basic', "msg-$i")->get;
            }
            Future::IO->sleep(0.3)->get;

            is(scalar @received, 3, 'received all 3 messages');
            is($received[0]{type},    'message',          'first msg type');
            is($received[0]{channel}, 'test:onmsg:basic', 'first msg channel');
            is($received[0]{data},    'msg-1',            'first msg data');
            is($received[0]{pattern}, undef,              'pattern undef for message');

            $subscriber->disconnect;
        };

        # Full end-to-end backpressure timing is flaky in this test
        # harness because the synchronous-callback path is extremely
        # tight — messages are dispatched as soon as frames arrive,
        # which can race the publisher. The backpressure LOGIC is
        # covered by the unit test below (`_dispatch_frame returns
        # Future when callback does`) and the failed-Future
        # integration test. The end-to-end timing test is documented
        # as a known gap pending a deterministic sync primitive.

        subtest 'callback returning a failed Future routes to on_error' => sub {
            # Fresh publisher too — the shared one can linger in a
            # state that interacts oddly with the fatal-close sequence.
            my $pub = _make_publisher();
            my $subscriber = _make_subscriber();
            my $err_seen;
            my $sub = $subscriber->subscribe('test:onmsg:future-fail')->get;
            $sub->on_error(sub {
                my ($s, $err) = @_;
                $err_seen = $err;
            });
            $sub->on_message(sub {
                return Future->fail("callback-future-boom");
            });

            $pub->publish('test:onmsg:future-fail', 'x')->get;
            Future::IO->sleep(0.3)->get;

            like($err_seen, qr/callback-future-boom/, 'on_error fired with callback Future failure');
            ok($sub->is_closed, 'subscription closed after fatal error');
            eval { $subscriber->disconnect };
            eval { $pub->disconnect };
        };

        subtest 'callback returning a Future delays next read until it resolves' => sub {
            my $subscriber = _make_subscriber();
            my @received;
            my $gate = Future->new;
            my $sub = $subscriber->subscribe('test:onmsg:backpressure')->get;
            $sub->on_message(sub {
                my ($s, $msg) = @_;
                push @received, $msg->{data};
                # First message blocks on the gate; subsequent return
                # undef so the driver can drain.
                return @received == 1 ? $gate : undef;
            });

            for my $i (1..3) {
                $publisher->publish('test:onmsg:backpressure', "msg-$i")->get;
            }
            Future::IO->sleep(0.3)->get;

            is(scalar @received, 1, 'driver delivered 1 message then blocked on Future');
            is($received[0], 'msg-1', 'first message delivered');

            $gate->done;
            Future::IO->sleep(0.3)->get;
            is(scalar @received, 3, 'remaining messages delivered after gate released');

            $subscriber->disconnect;
        };

        # Subsequent tasks (8, 9, 10) add more `subtest` blocks here,
        # inside the same _with_redis { ... } body.
    };
}

done_testing;
