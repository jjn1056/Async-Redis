# t/95-connection-lifetime/task-ownership.t
#
# Background work nobody awaits directly (an auto-pipeline submit, a
# subscription's callback driver) must be owned by something for as long
# as it runs. If it were not, it would be freed mid-flight: its callers
# would wait forever, and Future::AsyncAwait would warn that it lost its
# returning future.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis cleanup_keys);
use Future::IO;
use Time::HiRes qw(time);
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

my %base = (host => $ENV{REDIS_HOST} // 'localhost');

SKIP: {
    my $redis = skip_without_redis();

    subtest 'an auto-pipeline batch waiting on the write gate completes' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $r = Async::Redis->new(%base, auto_pipeline => 1);
        run { $r->connect };
        # Bounded: without an owner for the batch these would never complete.
        is [map { settle($r->set("lt:own:$_", "v$_")) } 1 .. 3], [('done') x 3],
            'auto-pipelined SETs complete';

        # A large write holds the connection's write gate for several loop
        # turns; the auto-pipelined GETs flush meanwhile and must wait.
        my $big  = $r->_execute_pipeline([['SET', 'lt:own:big', 'x' x 8_000_000]]);
        my @gets = map { $r->get("lt:own:$_") } 1 .. 3;
        run { Future::IO->sleep(0) };
        ok !$big->is_ready, 'the large write is still holding the gate';

        is [map { settle($_, 10) } $big, @gets], [('done') x 4], 'everything completes';
        is [map { $_->get } @gets], [qw(v1 v2 v3)], 'the GETs in order';
        is \@warnings, [], 'no warnings';
        eval { $r->disconnect };
    };

    subtest 'a callback-mode subscription keeps receiving' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $admin = Async::Redis->new(%base);
        run { $admin->connect };
        my $r = Async::Redis->new(%base);
        run { $r->connect };

        my $sub = run { $r->subscribe('lt:own:chan') };
        my @got;
        $sub->on_message(sub { push @got, $_[1]{data} });
        run { $admin->publish('lt:own:chan', "m$_") } for 1 .. 3;

        my $until = time + 2;
        run { Future::IO->sleep(0.01) } while @got < 3 && time < $until;
        is \@got, [qw(m1 m2 m3)], 'every message reaches the callback';
        is \@warnings, [], 'no warnings';
        eval { $r->disconnect };
        eval { $admin->disconnect };
    };

    cleanup_keys($redis, 'lt:own:*');
}

done_testing;
