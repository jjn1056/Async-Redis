# t/50-pubsub/reconnect-handoff.t
#
# Covers the pub/sub reconnect handoff as the unified reader performs it:
#
#   _reader_fatal
#     -> $subscription->_pause_for_reconnect   (keep channels, stop the driver)
#     -> $redis->_reconnect_async($subscription)
#          -> _reconnect
#          -> $subscription->_resume_after_reconnect  (replay, on_reconnect,
#                                                      restart the driver)
#
# and the no-reconnect branch, where _reader_fatal routes to _fail_fatal
# instead so a blocked next() sees the typed error.
#
# t/50-pubsub/reconnect.t covers reconnect from the consumer's side (messages
# keep arriving). This file pins the handoff itself: which collaborator runs,
# in what order, and what state each one is required to leave behind.

use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis qw(run await_f);
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;
use Future;

# --- Unit tests (no Redis needed) ---

subtest '_pause_for_reconnect stops the driver without closing the subscription' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub   = Async::Redis::Subscription->new(redis => $redis);
    $sub->_add_channel('chan:a');
    $sub->_add_pattern('events.*');

    # A next() suspended in _dequeue, and a running driver task.
    my $waiter = Future->new;
    $sub->{_message_waiter} = $waiter;
    my $driver = Future->new;
    $sub->{_driver_step} = $driver;

    $sub->_pause_for_reconnect;

    is($sub->{_paused}, 1, 'subscription marked paused');
    ok($waiter->is_ready, 'suspended _dequeue woken so the driver loop exits');
    ok($driver->is_cancelled, 'driver future cancelled (no two drivers after resume)');

    # The channels must survive: _resume_after_reconnect replays from them.
    ok(!$sub->is_closed, 'pause does not close the subscription');
    is([sort $sub->channels], ['chan:a'], 'channels retained for replay');
    is([sort $sub->patterns], ['events.*'], 'patterns retained for replay');
};

subtest '_reader_fatal hands a live subscription to _reconnect_async' => sub {
    my $redis = Async::Redis->new(host => 'localhost', reconnect => 1);
    my $sub   = Async::Redis::Subscription->new(redis => $redis);
    $sub->_add_channel('chan:a');

    $redis->{_subscription} = $sub;
    $redis->{in_pubsub}     = 1;
    $redis->{connected}     = 1;

    # Spy on the handoff target. This records the call; the routing decision
    # under test (_reader_fatal choosing this branch) is the real code.
    my @handoffs;
    no warnings 'redefine';
    local *Async::Redis::_reconnect_async = sub { push @handoffs, $_[1] };

    $redis->_reader_fatal(
        Async::Redis::Error::Connection->new(message => 'stream died')
    );

    is($sub->{_paused}, 1, 'subscription paused before the reconnect starts');
    is(scalar @handoffs, 1, '_reconnect_async invoked exactly once');
    ok($handoffs[0] && $handoffs[0] == $sub, 'handed the active subscription');
    ok(!$sub->is_closed, 'subscription left open for the resume path');
    is($redis->{in_pubsub}, 0, 'connection state torn down before reconnect');
};

subtest '_reader_fatal fails the subscription when reconnect is disabled' => sub {
    my $redis = Async::Redis->new(host => 'localhost', reconnect => 0);
    my $sub   = Async::Redis::Subscription->new(redis => $redis);
    $sub->_add_channel('chan:a');

    $redis->{_subscription} = $sub;
    $redis->{in_pubsub}     = 1;
    $redis->{connected}     = 1;

    my @handoffs;
    no warnings 'redefine';
    local *Async::Redis::_reconnect_async = sub { push @handoffs, $_[1] };

    my $typed = Async::Redis::Error::Connection->new(message => 'stream died');
    $redis->_reader_fatal($typed);

    is(scalar @handoffs, 0, 'no reconnect attempted');
    ok($sub->is_closed, 'subscription closed');
    ok(!$sub->{_paused}, 'not left in the paused state');

    # A caller blocked in next() must see the typed error, not undef.
    my $err = dies { run { $sub->next } };
    like("$err", qr/stream died/, 'blocked next() rethrows the typed error');
};

subtest 'reconnect exhaustion reaches the consumer, not the original read error' => sub {
    my $redis = Async::Redis->new(
        host                   => 'localhost',
        reconnect              => 1,
        reconnect_max_attempts => 1,
        reconnect_delay        => 0,
        reconnect_delay_max    => 0,
        reconnect_jitter       => 0,
    );
    my $sub = Async::Redis::Subscription->new(redis => $redis);
    $sub->_add_channel('chan');

    $redis->{_subscription} = $sub;
    $redis->{in_pubsub}     = 1;
    $redis->{connected}     = 1;

    # Every reconnect attempt fails, so the cap is exhausted.
    no warnings 'redefine';
    local *Async::Redis::connect = async sub {
        die Async::Redis::Error::Disconnected->new(message => 'connect failed');
    };

    # The read error starts recovery. Recovery then exhausts the cap. The
    # consumer-facing error must be the exhaustion, because that reports
    # recovery was attempted and failed; the read error is only the cause
    # that began it.
    $redis->_reader_fatal(
        Async::Redis::Error::Connection->new(message => 'read failed')
    );

    # Drive the loop until _reconnect_async's on_fail has fired _fail_fatal.
    for (1 .. 200) {
        last if $sub->{_fatal_error};
        run { Future::IO->sleep(0.01) };
    }
    ok($sub->{_fatal_error}, 'reconnect task gave up and failed the subscription');

    my $err = dies { run { $sub->next } };
    like("$err", qr/Reconnect gave up after 1 attempts/,
        'consumer sees the reconnect exhaustion error');
    unlike("$err", qr/read failed/,
        'original read error does not mask reconnect exhaustion');
};

# --- Integration tests (require Redis) ---

SKIP: {
    my $test_redis = eval {
        my $r = Async::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        run { $r->connect };
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    # Drop the connection the way a real peer does: CLIENT KILL issued from a
    # separate connection, since CLIENT is forbidden once we enter pub/sub
    # mode. The subscriber's client ID must be captured before subscribing.
    subtest '_resume_after_reconnect replays and clears the paused state' => sub {
        my $pub = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $pub->connect };

        my $sub_redis = Async::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            reconnect       => 1,
            reconnect_delay => 0.1,
        );
        run { $sub_redis->connect };
        my $sub_client_id = run { $sub_redis->client('ID') };

        my $subscription = run { $sub_redis->psubscribe('handoff:*') };

        my $reconnected = 0;
        $subscription->on_reconnect(sub { $reconnected++ });

        run { $pub->client('KILL', 'ID', $sub_client_id) };

        # Publish into the reconnect window. Receiving this proves the replay
        # actually re-registered the pattern on the new socket.
        my $post_f = (async sub {
            await Future::IO->sleep(0.3);
            await $pub->publish('handoff:one', 'after-reconnect');
        })->();

        my $next_f    = $subscription->next;
        my $timeout_f = Future::IO->sleep(5)->then(sub {
            Future->fail('Timed out waiting for the replayed subscription');
        });
        await_f(Future->wait_any($next_f, $timeout_f));
        my $msg = $next_f->get;

        is($msg->{data}, 'after-reconnect', 'message arrives on the replayed pattern');
        is($subscription->{_paused}, 0, 'paused flag cleared by the resume path');
        is($reconnected, 1, 'on_reconnect fired once from the resume path');
        is([$subscription->patterns], ['handoff:*'], 'pattern still tracked');
        ok(!$subscription->is_closed, 'subscription still open');

        eval { run { $post_f } };
        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };
}

done_testing;
