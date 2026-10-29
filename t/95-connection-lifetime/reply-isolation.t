# t/95-connection-lifetime/reply-isolation.t
#
# A command's outcome depends only on its own reply and on the fate of the
# connection it was sent on. One command's Redis error must not fail another
# command, a failure from a closed connection must not reach a later one, and
# a reader that dies must fail every kind of pending submission rather than
# leave some of them waiting forever.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::AsyncAwait;
use Future::IO;
use Future;
use Async::Redis;
use Scalar::Util qw(refaddr);

$SIG{PIPE} = 'IGNORE';

# Make $target's reader die on its next decode, as an unhandled coding bug
# would. Other clients are unaffected, so a publisher in the same test cannot
# consume the trap. Returns a guard that restores the original when it goes out of scope.
sub arm_reader_bug {
    my ($target) = @_;
    my $orig  = \&Async::Redis::_decode_response_result;
    my $armed = 1;
    no warnings 'redefine';
    *Async::Redis::_decode_response_result = sub {
        if ($armed && refaddr($_[0]) == refaddr($target)) { $armed = 0; die "INJECTED_READER_BUG\n" }
        return $orig->(@_);
    };
    return bless sub { no warnings 'redefine'; *Async::Redis::_decode_response_result = $orig },
        'ReaderBugGuard';
}
sub ReaderBugGuard::DESTROY { $_[0]->() }

sub new_client {
    Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', @_);
}

SKIP: {
    my $redis = skip_without_redis();

    # A short-blocking command at the head of the wire holds every reply back
    # until all three callers are already waiting, so the error and the PONG
    # are dispatched together in one pass.
    sub issue_error_with_bystander {
        my ($r) = @_;
        run { $r->set('iso:str', 'x') };
        run { $r->del('iso:none') };
        my $hold = $r->command('BLPOP', 'iso:none', '0.2');
        my $lpush = $r->command('LPUSH', 'iso:str', 'y');
        my $ping  = $r->command('PING');
        return ($hold, $lpush, $ping);
    }

    subtest "B9: one command's Redis error does not fail a concurrent command" => sub {
        my $r = new_client(); run { $r->connect };
        my ($hold, $lpush, $ping) = issue_error_with_bystander($r);
        settle($_) for $hold, $lpush, $ping;

        is settle($lpush), 'failed', 'LPUSH on a string fails';
        like "" . (failure_of($lpush) // ''), qr/WRONGTYPE/, 'with WRONGTYPE';
        is settle($ping), 'done', 'the concurrent PING is unaffected';
        is scalar($ping->is_done ? $ping->get : undef), 'PONG', 'and returns PONG';
        eval { $r->disconnect };
    };

    subtest "B8: a disconnect's leftover failure does not reach the next connection" => sub {
        my $r = new_client(); run { $r->connect };
        run { $r->del('iso:missing:a', 'iso:missing:b') };
        my $fa = $r->command('BLPOP', 'iso:missing:a', '5');
        my $fb = $r->command('BLPOP', 'iso:missing:b', '5');
        run { Future::IO->sleep(0.2) };
        $r->disconnect;
        is settle($fa), 'failed', 'first BLPOP fails on disconnect';
        is settle($fb), 'failed', 'second BLPOP fails on disconnect';

        run { $r->connect };
        my $ping = $r->command('PING');
        is settle($ping), 'done', 'PING on the new connection succeeds';
        note 'PING failed with: ' . failure_of($ping) if $ping->is_failed;
        eval { $r->disconnect };
    };

    subtest 'one failure among many' => sub {
        my $r = new_client(); run { $r->connect };
        run { $r->set('iso:str', 'x') };
        run { $r->del('iso:none') };
        my $hold = $r->command('BLPOP', 'iso:none', '0.2');
        my $lpush = $r->command('LPUSH', 'iso:str', 'y');
        my @pings = map { $r->command('PING') } 1 .. 49;

        settle($_) for $hold, $lpush, @pings;
        is settle($lpush), 'failed', 'the LPUSH fails';
        is scalar(grep { $_->is_done } @pings), 49, 'all 49 PINGs succeed';
        eval { $r->disconnect };
    };

    subtest 'B11: reader crash ends a pipeline instead of hanging' => sub {
        my $r = new_client(); run { $r->connect };
        run { $r->set('iso:k', 'v') };
        my $guard = arm_reader_bug($r);
        my $pipe = $r->pipeline;
        $pipe->get('iso:k');
        $pipe->get('iso:k');
        my $f = $pipe->execute;
        # A pipeline reports transport failures per slot and still completes.
        is settle($f), 'done', 'pipeline completes instead of hanging';
        my $slots = $f->is_done ? $f->get : [];
        is scalar(@$slots), 2, 'one result per command';
        isa_ok $_, 'Async::Redis::Error::Connection' for @$slots;
        undef $guard;
        eval { $r->disconnect };
    };

    subtest 'B11: reader crash fails an auto-pipelined command instead of hanging' => sub {
        my $r = new_client(auto_pipeline => 1); run { $r->connect };
        run { $r->set('iso:k', 'v') };
        my $guard = arm_reader_bug($r);
        my $f = $r->get('iso:k');
        is settle($f), 'failed', 'auto-pipelined GET fails (not hung, not done)';
        undef $guard;
        eval { $r->disconnect };
    };

    subtest 'reader crash while subscribed does not hang' => sub {
        my $sub_redis = new_client(reconnect => 0); run { $sub_redis->connect };
        my $pub = new_client(); run { $pub->connect };
        my $sub = run { $sub_redis->subscribe('iso:chan') };

        my $guard = arm_reader_bug($sub_redis);
        my $next  = $sub->next;
        my $published = $pub->publish('iso:chan', 'hello');
        is settle($next), 'failed', 'blocked next() fails (not hung, not delivered)';
        isa_ok failure_of($next), 'Async::Redis::Error';
        settle($published);
        undef $guard;
        eval { $pub->disconnect };
        eval { $sub_redis->disconnect };
    };

    # Errors stay with the caller that owns them.

    subtest 'own error is unchanged' => sub {
        my $r = new_client(); run { $r->connect };
        my ($hold, $lpush, $ping) = issue_error_with_bystander($r);
        settle($_) for $hold, $lpush, $ping;
        my $err = failure_of($lpush);
        isa_ok $err, 'Async::Redis::Error::Redis';
        is eval { $err->type }, 'WRONGTYPE', 'error type is WRONGTYPE';
        eval { $r->disconnect };
    };

    subtest 'unawaited failure does not reach later command' => sub {
        my $r = new_client(); run { $r->connect };
        run { $r->set('iso:str', 'x') };
        my $lpush = $r->command('LPUSH', 'iso:str', 'y');   # never awaited
        run { Future::IO->sleep(0.1) };
        my $ping = $r->command('PING');
        is settle($ping), 'done', 'later PING succeeds';
        eval { $r->disconnect };
    };

    subtest 'pipeline slot error stays in pipeline' => sub {
        my $r = new_client(); run { $r->connect };
        run { $r->set('iso:str', 'x') };
        my $pipe = $r->pipeline;
        $pipe->lpush('iso:str', 'y');
        my $pf   = $pipe->execute;
        my $ping = $r->command('PING');
        is settle($ping), 'done', 'concurrent PING succeeds';
        is settle($pf), 'done', 'pipeline itself completes';
        isa_ok(($pf->get)->[0], 'Async::Redis::Error::Redis');
        eval { $r->disconnect };
    };

    cleanup_keys($redis, 'iso:*');
}

done_testing;
