# t/95-connection-lifetime/stale-gate-holder.t
#
# A submission still holding the write gate when its connection is closed
# must not act on the next connection: it must not fail the new
# connection's commands, and it must not let two submitters hold the gate
# at once (the gate keeps inflight order equal to wire order, which is how
# replies are matched to callers).

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::IO;
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

sub new_reconnecting {
    Async::Redis->new(
        host            => $ENV{REDIS_HOST} // 'localhost',
        reconnect       => 1,
        reconnect_delay => 0.01,
    );
}

SKIP: {
    my $redis = skip_without_redis();

    todo 'connection lifetime (Plan B)' => sub {
        subtest 'B3: a stale write holder cannot fail the new connection' => sub {
            my @failures;
            for my $i (1 .. 15) {
                my $r = new_reconnecting();
                run { $r->connect };
                my $fa = $r->command('SET', 'lt:a', 'a');   # holds the gate
                $r->disconnect;
                my $fb = $r->command('SET', 'lt:b', 'b');   # reconnects
                settle($fa);
                push @failures, "iteration $i: " . failure_of($fb)
                    unless settle($fb) eq 'done';
                eval { $r->disconnect };
            }
            is \@failures, [], 'the new connection\'s command succeeds every time';
        };

        subtest 'B4: write gate stays exclusive across disconnect' => sub {
            my @log;
            no warnings 'redefine';
            my $orig = \&Async::Redis::_send;
            local *Async::Redis::_send = sub {
                my (undef, $data) = @_;
                my ($tag) = $data =~ /(lt:gate:[abc])/;
                $tag //= 'other';
                push @log, "enter $tag";
                my $f = $orig->(@_);
                $f->on_ready(sub { push @log, "exit $tag" });
                return $f;
            };

            my $r = new_reconnecting();
            run { $r->connect };
            my $fa = $r->command('SET', 'lt:gate:a', 'a');   # in progress
            $r->disconnect;
            my $fb = $r->command('SET', 'lt:gate:b', 'b');   # takes the gate, reconnects
            Future::IO->sleep(0)->get;                        # one loop turn
            my $fc = $r->command('SET', 'lt:gate:c', 'c');   # must queue behind B
            settle($_) for $fa, $fb, $fc;

            my ($b_exit)  = grep { $log[$_] eq 'exit lt:gate:b'  } 0 .. $#log;
            my ($c_enter) = grep { $log[$_] eq 'enter lt:gate:c' } 0 .. $#log;
            ok defined $b_exit && defined $c_enter, 'both B and C wrote'
                or diag "send log: @log";
            ok defined $b_exit && defined $c_enter && $c_enter > $b_exit,
                'C did not start writing until B finished'
                or diag "send log: @log";
            eval { $r->disconnect };
        };
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
