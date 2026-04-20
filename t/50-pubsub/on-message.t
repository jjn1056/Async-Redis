# t/50-pubsub/on-message.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis';
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;

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

done_testing;
