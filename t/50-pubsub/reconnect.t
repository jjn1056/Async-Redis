# t/50-pubsub/reconnect.t
#
# Test pub/sub auto-resubscription on reconnect
#
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis qw(init_loop run skip_without_redis);
use Future::AsyncAwait;
use Test2::V0;
use Async::Redis;
use Future;

my $loop = init_loop();

# --- Unit tests (no Redis needed) ---

subtest 'get_replay_commands returns correct commands' => sub {
    my $redis = Async::Redis->new(host => 'localhost');
    my $sub = Async::Redis::Subscription->new(redis => $redis);

    # Track some subscriptions
    $sub->_add_channel('chan:a');
    $sub->_add_channel('chan:b');
    $sub->_add_pattern('events.*');

    my @commands = $sub->get_replay_commands;

    is(scalar @commands, 2, 'two replay commands (SUBSCRIBE + PSUBSCRIBE)');

    # Find the SUBSCRIBE command
    my ($sub_cmd) = grep { $_->[0] eq 'SUBSCRIBE' } @commands;
    ok($sub_cmd, 'has SUBSCRIBE command');
    is(scalar @$sub_cmd, 3, 'SUBSCRIBE has 2 channels');
    ok(
        (grep { $_ eq 'chan:a' } @$sub_cmd) && (grep { $_ eq 'chan:b' } @$sub_cmd),
        'SUBSCRIBE includes both channels'
    );

    # Find the PSUBSCRIBE command
    my ($psub_cmd) = grep { $_->[0] eq 'PSUBSCRIBE' } @commands;
    ok($psub_cmd, 'has PSUBSCRIBE command');
    is($psub_cmd->[1], 'events.*', 'PSUBSCRIBE has correct pattern');
};

subtest '_reset_connection clears in_pubsub flag' => sub {
    my $redis = Async::Redis->new(host => 'localhost');

    # Simulate being in pubsub mode
    $redis->{in_pubsub} = 1;
    $redis->{connected} = 1;
    $redis->{socket} = undef;  # no real socket

    $redis->_reset_connection('test');

    is($redis->{in_pubsub}, 0, 'in_pubsub cleared after reset');
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
    skip "Redis not available: $@", 5 unless $test_redis;
    $test_redis->disconnect;

    # Timeout for each integration subtest — prevents hangs when
    # reconnection isn't implemented yet
    my $TEST_TIMEOUT = 5;

    subtest 'subscriber reconnects and resubscribes after connection drop' => sub {
        # Publisher — separate connection
        my $pub = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        run { $pub->connect };

        # Subscriber — with reconnect enabled
        my $sub_redis = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 1,
            reconnect_delay => 0.1,
        );
        run { $sub_redis->connect };

        # Subscribe to a channel
        my $subscription = run { $sub_redis->subscribe('reconnect:test') };
        ok($subscription, 'subscribed');
        is([$subscription->channels], ['reconnect:test'], 'tracking channel');

        # Verify it works before disconnect
        my $pre_msg_future = (async sub {
            await Future::IO->sleep(0.1);
            await $pub->publish('reconnect:test', 'before_disconnect');
        })->();

        my $msg1 = run { $subscription->next };
        is($msg1->{data}, 'before_disconnect', 'received message before disconnect');
        run { $pre_msg_future };

        # Force disconnect — simulate Redis restart
        close $sub_redis->{socket};
        $sub_redis->{connected} = 0;

        # Publish a message after disconnect (this one will be lost — expected)
        run { $pub->publish('reconnect:test', 'during_disconnect') };

        # Now try to read — this should trigger reconnect + resubscribe
        my $post_msg_future = (async sub {
            await Future::IO->sleep(0.3);  # give time for reconnect
            await $pub->publish('reconnect:test', 'after_reconnect');
        })->();

        # First next() returns the reconnected notification
        my $next_f = $subscription->next;
        my $timeout_f = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
            Future->fail("Timed out waiting for reconnect notification");
        });
        my $notify = eval { $loop->await(Future->wait_any($next_f, $timeout_f)); $next_f->get };
        my $error = $@;

        if ($error) {
            fail("got reconnected notification: $error");
        } else {
            is($notify->{type}, 'reconnected', 'got reconnected notification first');
        }

        # Second next() returns the actual message
        if (!$error) {
            my $next_f2 = $subscription->next;
            my $timeout_f2 = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
                Future->fail("Timed out waiting for message after reconnect");
            });
            my $msg2 = eval { $loop->await(Future->wait_any($next_f2, $timeout_f2)); $next_f2->get };
            if ($@) {
                fail("received message after reconnect: $@");
            } else {
                is($msg2->{data}, 'after_reconnect', 'received message after reconnect');
            }
        }

        eval { run { $post_msg_future } };

        # Verify subscription state is intact
        is([$subscription->channels], ['reconnect:test'], 'still tracking channel');
        ok(!$subscription->is_closed, 'subscription not closed');

        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };

    subtest 'reconnect delivers notification message' => sub {
        my $pub = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        run { $pub->connect };

        my $sub_redis = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 1,
            reconnect_delay => 0.1,
        );
        run { $sub_redis->connect };

        my $subscription = run { $sub_redis->subscribe('notify:test') };

        # Force disconnect
        close $sub_redis->{socket};
        $sub_redis->{connected} = 0;

        # Schedule a publish so next() eventually returns
        my $publish_future = (async sub {
            await Future::IO->sleep(0.3);
            await $pub->publish('notify:test', 'after');
        })->();

        # First message after reconnect should be a reconnected notification
        my $next_f = $subscription->next;
        my $timeout_f = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
            Future->fail("Timed out waiting for reconnect notification");
        });
        my $msg = eval { $loop->await(Future->wait_any($next_f, $timeout_f)); $next_f->get };
        my $error = $@;

        if ($error) {
            fail("got reconnected notification: $error");
        } else {
            is($msg->{type}, 'reconnected', 'got reconnected notification');
            ok($msg->{channels}, 'notification includes channels');
        }

        # Next message is the actual published message
        if (!$error) {
            my $next_f2 = $subscription->next;
            my $timeout_f2 = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
                Future->fail("Timed out waiting for message after reconnect");
            });
            my $msg2 = eval { $loop->await(Future->wait_any($next_f2, $timeout_f2)); $next_f2->get };
            if ($@) {
                fail("got real message: $@");
            } else {
                is($msg2->{type}, 'message', 'then got real message');
                is($msg2->{data}, 'after', 'correct data');
            }
        }

        eval { run { $publish_future } };
        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };

    subtest 'psubscribe reconnects with patterns' => sub {
        my $pub = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        run { $pub->connect };

        my $sub_redis = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 1,
            reconnect_delay => 0.1,
        );
        run { $sub_redis->connect };

        my $subscription = run { $sub_redis->psubscribe('precon:*') };
        is([$subscription->patterns], ['precon:*'], 'tracking pattern');

        # Force disconnect
        close $sub_redis->{socket};
        $sub_redis->{connected} = 0;

        my $publish_future = (async sub {
            await Future::IO->sleep(0.3);
            await $pub->publish('precon:chan1', 'pattern_msg');
        })->();

        # Should get reconnected notification first
        my $next_f = $subscription->next;
        my $timeout_f = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
            Future->fail("Timed out waiting for reconnect notification (pattern)");
        });
        my $msg1 = eval { $loop->await(Future->wait_any($next_f, $timeout_f)); $next_f->get };
        my $error = $@;

        if ($error) {
            fail("got reconnected notification for pattern: $error");
        } else {
            is($msg1->{type}, 'reconnected', 'got reconnected notification for pattern');
        }

        # Then the actual pattern-matched message
        if (!$error) {
            my $next_f2 = $subscription->next;
            my $timeout_f2 = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
                Future->fail("Timed out waiting for pmessage after reconnect");
            });
            my $msg2 = eval { $loop->await(Future->wait_any($next_f2, $timeout_f2)); $next_f2->get };
            if ($@) {
                fail("got pmessage after reconnect: $@");
            } else {
                is($msg2->{type}, 'pmessage', 'got pmessage after reconnect');
                is($msg2->{data}, 'pattern_msg', 'correct pattern message data');
                is($msg2->{pattern}, 'precon:*', 'correct pattern');
            }
        }

        eval { run { $publish_future } };
        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };

    subtest 'multi-channel resubscribe after reconnect' => sub {
        my $pub = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        run { $pub->connect };

        my $sub_redis = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 1,
            reconnect_delay => 0.1,
        );
        run { $sub_redis->connect };

        # Subscribe to multiple channels
        my $subscription = run { $sub_redis->subscribe('multi:a', 'multi:b', 'multi:c') };
        is(scalar $subscription->channel_count, 3, 'subscribed to 3 channels');

        # Force disconnect
        close $sub_redis->{socket};
        $sub_redis->{connected} = 0;

        my $publish_future = (async sub {
            await Future::IO->sleep(0.3);
            await $pub->publish('multi:a', 'msg_a');
            await $pub->publish('multi:b', 'msg_b');
            await $pub->publish('multi:c', 'msg_c');
        })->();

        # Reconnected notification
        my $next_f = $subscription->next;
        my $timeout_f = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
            Future->fail("Timed out waiting for reconnect notification (multi)");
        });
        my $notify = eval { $loop->await(Future->wait_any($next_f, $timeout_f)); $next_f->get };
        my $error = $@;

        if ($error) {
            fail("got reconnected notification: $error");
        } else {
            is($notify->{type}, 'reconnected', 'got reconnected notification');
        }

        # Should receive from all three channels
        if (!$error) {
            my %received;
            for my $i (1..3) {
                my $next_fi = $subscription->next;
                my $timeout_fi = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
                    Future->fail("Timed out waiting for message $i");
                });
                my $msg = eval { $loop->await(Future->wait_any($next_fi, $timeout_fi)); $next_fi->get };
                last if $@;
                $received{$msg->{channel}} = $msg->{data};
            }

            is($received{'multi:a'}, 'msg_a', 'received from channel a');
            is($received{'multi:b'}, 'msg_b', 'received from channel b');
            is($received{'multi:c'}, 'msg_c', 'received from channel c');
        }

        eval { run { $publish_future } };
        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };

    subtest 'no reconnect when reconnect disabled' => sub {
        my $sub_redis = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 0,
        );
        run { $sub_redis->connect };

        my $subscription = run { $sub_redis->subscribe('norecon:test') };

        # Force disconnect
        close $sub_redis->{socket};
        $sub_redis->{connected} = 0;

        # next() should throw, not reconnect
        my $next_f = $subscription->next;
        my $timeout_f = Future::IO->sleep($TEST_TIMEOUT)->then(sub {
            Future->fail("Timed out — next() should have thrown immediately");
        });
        my $error;
        eval { $loop->await(Future->wait_any($next_f, $timeout_f)); $next_f->get };
        $error = $@;

        ok($error, 'error thrown when reconnect disabled');
        like("$error", qr/connect|disconnect|fileno|closed/i, 'error is connection-related');
    };
}

done_testing;
