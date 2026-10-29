use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis ();   # selects the suite's Future::IO event loop
use Future::AsyncAwait;
use Future::IO;
use Future;
use Scalar::Util qw(blessed);
use Async::Redis;

plan skip_all => 'REDIS_HOST not set' unless $ENV{REDIS_HOST};

# If the reader task dies with an unhandled exception (a coding bug that
# bypasses _run_reader's explicit _reader_fatal paths), the failure MUST
# reach awaiting callers as a typed error. Otherwise inflight response
# futures are never failed and the caller waits forever while the client
# still reports connected=1. _ensure_reader routes a failed reader into
# _reader_fatal, which fails every inflight entry.

subtest 'reader unhandled exception propagates to awaiting caller' => sub {
    (async sub {
        my $r = Async::Redis->new(
            host => $ENV{REDIS_HOST},
            port => $ENV{REDIS_PORT} // 6379,
        );
        await $r->connect;

        # Baseline: ensure normal command flow works before the trap.
        await $r->set('reader_exc_test', 'before');

        # Monkey-patch _decode_response_result to die unhandled on its next
        # call. Simulates an arbitrary coding bug in the reader's frame
        # processing that escapes _reader_fatal routing.
        my $orig  = \&Async::Redis::_decode_response_result;
        my $armed = 1;
        {
            no warnings 'redefine';
            *Async::Redis::_decode_response_result = sub {
                if ($armed) {
                    $armed = 0;
                    die "INJECTED_READER_BUG\n";
                }
                return $orig->(@_);
            };
        }

        # Issue a command. The reader will try to decode its response,
        # hit the injected die, and fail; the reader's failure fails this
        # command's inflight entry.
        my $set_f = $r->set('reader_exc_test', 'after');

        # Callback-based outcome capture (avoid rethrow via await).
        my $outcome = 'unknown';
        my $captured_err;
        my $done = Future->new;

        $set_f->on_done(sub {
            $outcome = 'COMPLETED';
            $done->done unless $done->is_ready;
        });
        $set_f->on_fail(sub {
            $outcome = 'FAILED';
            $captured_err = $_[0];
            $done->done unless $done->is_ready;
        });

        # Hung-detection: 2 second ceiling.
        my $timeout = Future::IO->sleep(2);
        $timeout->on_done(sub {
            if ($outcome eq 'unknown') {
                $outcome = 'HUNG';
                $done->done unless $done->is_ready;
            }
        });

        await $done;

        is $outcome, 'FAILED', 'reader bug surfaced to awaiting caller (not HUNG)';
        ok defined $captured_err, 'caller received an error';

        # Restore and clean up.
        {
            no warnings 'redefine';
            *Async::Redis::_decode_response_result = $orig;
        }
        eval { $r->disconnect };
    })->()->get;
};

done_testing;
