# t/93-socket-cleanup/pubsub-read-orphan.t
#
# Guards socket teardown for a connection parked in a pub/sub read.
#
# Under the unified single-reader model, Subscription::next does not read the
# socket itself: it awaits _dequeue on a queue fed by _run_reader, and
# _run_reader registers its Future::IO->read in _current_read_future.
# disconnect() depends on that registration to cancel the in-flight read
# BEFORE closing the socket, while fileno is still valid. Closing first would
# leave Future::IO holding a watcher on a dead descriptor, which corrupts the
# poll loop shared with every other connection.
#
# What these subtests pin down:
#   1. A next() left pending across disconnect readies promptly, with the
#      documented clean-close result (undef) rather than an orphan or error.
#   2. Cancelling a suspended listener loop and then disconnecting completes
#      without hanging at teardown or process exit.
#   3. Disconnecting one subscriber leaves the shared poll loop intact, so
#      other connections' pending reads still deliver.
#
# Contrast: close-with-watchers.t covers the same teardown for a normal
# command (BLPOP) rather than a pub/sub read.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(skip_without_redis run);
use Future::AsyncAwait;

# This test deliberately closes a socket with a pending read.
$SIG{PIPE} = 'IGNORE';

SKIP: {
    skip_without_redis();

    subtest 'disconnect with a pending pub/sub read does not orphan the read' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };

        my $r = Async::Redis->new(
            host      => $ENV{REDIS_HOST} // 'localhost',
            reconnect => 0,
        );
        run { $r->connect };

        my $sub = run { $r->psubscribe('orphan:pubsub:*') };
        ok($sub, 'psubscribe returned a subscription');

        # Start a pub/sub read. It blocks waiting for a message while the
        # reader holds a live Future::IO read watcher. We do NOT await it.
        my $next_f = $sub->next;
        ok(!$next_f->is_ready, 'pub/sub next() is pending before disconnect');

        my $fileno_before = fileno($r->{socket});
        ok(defined $fileno_before, "socket has valid fileno before disconnect");

        # The read disconnect() must cancel while the fileno is still valid.
        my $read_f = $r->{_current_read_future};
        ok($read_f && !$read_f->is_ready,
           'reader registered its in-flight read for disconnect to cancel');

        # Disconnect while the read is in flight.
        $r->disconnect;
        ok(!defined $r->{socket}, 'socket undef after disconnect');
        ok($read_f->is_cancelled, 'in-flight read cancelled before socket close');

        # Drive the loop so any cleanup / watcher teardown propagates.
        run { Future::IO->sleep(0.1) };

        ok($next_f->is_ready, 'pub/sub next() future is ready after disconnect')
            or diag "pub/sub read future orphaned by disconnect (never readied)";
        ok($next_f->is_done, 'pub/sub next() completed cleanly (not failed or cancelled)')
            or diag "next() unwound as an error instead of the clean-close path";

        # disconnect() closes the subscription, and a closed subscription
        # yields undef to a blocked next() (see Subscription POD for next).
        my @result = $next_f->is_done ? $next_f->result : ();
        is($result[0], undef, 'pub/sub next() returned undef per the clean-close contract');

        my @fileno_warnings = grep {
            /fileno|file descriptor|invalid|bad fd|not registered/i
        } @warnings;
        is(scalar(@fileno_warnings), 0,
           'no fileno-related warnings from pub/sub disconnect');
        diag("  $_") for @fileno_warnings;
    };

    # A fire-and-forget listener LOOP suspended on next(), cancelled, then the
    # connection disconnected — the teardown order a consumer performs when
    # shutting a subscriber down.
    subtest 'cancel a running pub/sub listener loop then disconnect (no hang)' => sub {
        my $r = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost', reconnect => 0,
        );
        run { $r->connect };
        my $sub = run { $r->psubscribe('orphan:loop:*') };

        my $listener_f = (async sub {
            while (my $msg = await $sub->next) { }
            return 'loop-ended';
        })->();
        ok(!$listener_f->is_ready, 'listener loop running (suspended on next)');

        $listener_f->cancel;
        $r->disconnect;

        # If the read watcher were orphaned, driving the loop here (or process
        # exit) hangs. Reaching the assertion at all means no hang.
        run { Future::IO->sleep(0.1) };

        ok($listener_f->is_ready, 'listener future ready after cancel+disconnect');
        pass('cancel+disconnect of a pub/sub listener completed without hanging');
    };

    # Closing ONE subscriber's socket while its read watcher is live must not
    # corrupt the SHARED Future::IO/IO::Async poll loop (see the
    # close-with-watchers.t header), which would hang or break OTHER
    # connections' pending reads.
    subtest 'disconnecting one pub/sub conn must not corrupt the shared loop' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };

        my $r1 = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', reconnect => 0);
        my $r2 = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', reconnect => 0);
        run { $r1->connect };
        run { $r2->connect };

        my $sub1 = run { $r1->psubscribe('orphan:r1:*') };
        my $sub2 = run { $r2->psubscribe('orphan:r2:*') };

        # Park both connections in a pub/sub read (each holds a live watcher).
        my $next1 = $sub1->next;
        my $next2 = $sub2->next;
        ok(!$next1->is_ready, 'r1 read pending');
        ok(!$next2->is_ready, 'r2 read pending');

        # Close r1's socket while its read watcher is live.
        $r1->disconnect;

        # r2 must still work: publish to its pattern via a 3rd connection and
        # confirm r2 receives it. If r1's teardown poisoned the shared loop,
        # awaiting r2's read hangs or dies in the loop implementation.
        my $pub = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', reconnect => 0);
        run { $pub->connect };
        run { $pub->publish('orphan:r2:test', 'hello') };

        my $got = run { $next2 };
        ok($got, 'r2 still receives a message after r1 disconnect');
        is($got->{data}, 'hello', 'r2 got the correct payload (shared loop intact)');

        my @loop_warnings = grep {
            /fileno|file descriptor|invalid|bad fd|not registered|undefined value/i
        } @warnings;
        is(scalar(@loop_warnings), 0, 'no poll-loop corruption warnings');
        diag("  $_") for @loop_warnings;

        run { $pub->disconnect; $r2->disconnect; Future::IO->sleep(0.05) };
    };
}

done_testing;
