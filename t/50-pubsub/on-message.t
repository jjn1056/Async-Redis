# t/50-pubsub/on-message.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis';
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;

sub _with_redis (&) {
    my ($code) = @_;
    my $publisher = eval {
        my $r = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        run { $r->connect };
        $r;
    };
    unless ($publisher) {
        skip "Redis not available: $@", 1;
        return;
    }
    my $subscriber = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    run { $subscriber->connect };
    $code->($publisher, $subscriber);
    $subscriber->disconnect;
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
        my ($publisher, $subscriber) = @_;

        subtest 'on_message receives messages published to subscribed channels' => sub {
            my @received;
            my $sub = run { $subscriber->subscribe('test:onmsg:basic') };
            $sub->on_message(sub {
                my ($s, $msg) = @_;
                push @received, $msg;
            });

            run {
                (async sub {
                    await Future::IO->sleep(0.1);
                    for my $i (1..3) {
                        await $publisher->publish('test:onmsg:basic', "msg-$i");
                    }
                    await Future::IO->sleep(0.3);
                })->();
            };

            is(scalar @received, 3, 'received all 3 messages');
            is($received[0]{type},    'message',          'first msg type');
            is($received[0]{channel}, 'test:onmsg:basic', 'first msg channel');
            is($received[0]{data},    'msg-1',            'first msg data');
            is($received[0]{pattern}, undef,              'pattern undef for message');
        };

        # Subsequent tasks (7, 8, 9, 10) add more `subtest` blocks here,
        # inside the same _with_redis { ... } body.
    };
}

done_testing;
