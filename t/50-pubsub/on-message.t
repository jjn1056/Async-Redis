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

done_testing;
