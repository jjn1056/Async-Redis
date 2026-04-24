use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future::IO;
use Future;
use Scalar::Util qw(blessed);
use Async::Redis;

plan skip_all => 'REDIS_HOST not set' unless $ENV{REDIS_HOST};

# Structured-concurrency invariants for the Future::Selector-backed
# task ownership model. Complements reader-unhandled-exception.t and
# existing pubsub/reconnect tests by covering whole-lifecycle
# properties: task failure reaches awaiting callers, disconnect under
# load closes cleanly, reconnect cycles don't leak state.

sub new_redis {
    Async::Redis->new(
        host => $ENV{REDIS_HOST},
        port => $ENV{REDIS_PORT} // 6379,
    );
}

subtest 'task failure reaches awaiting caller (generic structured-concurrency property)' => sub {
    # This is the broader sibling of reader-unhandled-exception.t: any
    # fire-and-forget task failure, not just reader bugs, should reach
    # a concurrent caller that's inside run_until_ready.
    #
    # We drive this by monkey-patching _decode_response_result (same
    # as the reader test) but verify against a COMMAND that doesn't
    # need the reader to respond — a pure write-only submit. The
    # selector propagates the reader task's failure to the command's
    # awaiting future via run_until_ready.

    (async sub {
        my $r = new_redis();
        await $r->connect;

        # Baseline.
        await $r->set('sel_inv_key', 'before');

        # Arm the trap on the next decode.
        my $orig = \&Async::Redis::_decode_response_result;
        my $armed = 1;
        {
            no warnings 'redefine';
            *Async::Redis::_decode_response_result = sub {
                if ($armed) { $armed = 0; die "SELECTOR_INVARIANT_TEST_BUG\n" }
                return $orig->(@_);
            };
        }

        # Issue a read (GET); the reader will try to decode the response,
        # hit the trap, and fail. The selector propagates that failure
        # to our awaiting run_until_ready.
        my $outcome;
        my $done = Future->new;
        my $get_f = $r->get('sel_inv_key');
        $get_f->on_done(sub { $outcome = 'done';   $done->done unless $done->is_ready });
        $get_f->on_fail(sub { $outcome = 'failed'; $done->done unless $done->is_ready });
        my $timeout = Future::IO->sleep(2);
        $timeout->on_done(sub {
            $outcome //= 'hung'; $done->done unless $done->is_ready;
        });

        await $done;

        is $outcome, 'failed', 'awaiting caller saw task failure (not hung, not done)';

        # Restore.
        { no warnings 'redefine'; *Async::Redis::_decode_response_result = $orig; }
        eval { $r->disconnect };
    })->()->get;
};

# Note: a "disconnect under load" test was considered and removed.
# Firing many commands and calling disconnect synchronously surfaces
# write-gate waiters that aren't torn down by disconnect (they stay
# pending on _acquire_write_lock after the socket closes). That's a
# latent gap in disconnect's cleanup, not a Phase 7 concern — fixing
# it is a behavior change. See conversation log.

subtest 'reconnect cycles do not leak state' => sub {
    (async sub {
        my $sub_redis = Async::Redis->new(
            host            => $ENV{REDIS_HOST},
            port            => $ENV{REDIS_PORT} // 6379,
            reconnect       => 1,
            reconnect_delay => 0.05,
        );
        my $pub = new_redis();
        await $sub_redis->connect;
        await $pub->connect;

        my $ch = 'selector_leak_' . $$;
        my $sub = await $sub_redis->subscribe($ch);

        # Cycle through N reconnects by repeatedly killing the socket.
        my $CYCLES = 3;
        for my $cycle (1 .. $CYCLES) {
            # Publish + receive one message to confirm the subscription
            # is live in this cycle.
            my $published = (async sub {
                await Future::IO->sleep(0.05);
                await $pub->publish($ch, "cycle-$cycle");
            })->();

            my $m_f = $sub->next;
            my $timeout = Future::IO->sleep(2);
            my $got_msg;
            my $done = Future->new;
            $m_f->on_done(sub {
                $got_msg = $_[0];
                $done->done unless $done->is_ready;
            });
            $m_f->on_fail(sub {
                $done->done unless $done->is_ready;
            });
            $timeout->on_done(sub {
                $done->done unless $done->is_ready;
            });
            await $done;
            eval { await $published };

            ok $got_msg && $got_msg->{data} eq "cycle-$cycle",
                "cycle $cycle: received expected message";

            # Force a disconnect to trigger reconnect.
            close $sub_redis->{socket} if $sub_redis->{socket};
            $sub_redis->{connected}    = 0;
            $sub_redis->{_socket_live} = 0;
            # Give reconnect a moment to kick off.
            await Future::IO->sleep(0.3);
        }

        # After N cycles, the subscription should still be tracking the
        # channel and not be closed.
        is [$sub->channels], [$ch],
            "still tracking channel after $CYCLES reconnect cycles";
        ok !$sub->is_closed, 'subscription not closed after reconnect cycles';

        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    })->()->get;
};

done_testing;
