# t/95-connection-lifetime/fork-child-exit.t
#
# A pre-fork server connects in the parent, then forks workers. A child
# that exits, or drops its copy of the client, without ever using it must
# leave the parent's connection working: the socket is shared, and only
# the process that made the connection may shut it down.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis);
use POSIX ();
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';

# Connect, fork, run $in_child in the child, and check the parent's
# connection afterwards.
sub parent_survives {
    my ($in_child) = @_;
    my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    run { $r->connect };
    is run { $r->ping }, 'PONG', 'parent connected before the fork';

    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        $in_child->($r);
        POSIX::_exit(0);   # not reached unless $in_child returns
    }
    waitpid($pid, 0);

    my $ping = $r->command('PING');
    is settle($ping), 'done', 'parent PING after the child is gone'
        or diag 'failed with: ' . failure_of($ping);
    is $ping->get, 'PONG', 'with PONG' if $ping->is_done;
    eval { $r->disconnect };
}

SKIP: {
    skip_without_redis();

    subtest 'B14: a child that exits leaves the parent connected' => sub {
        parent_survives(sub { exit 0 });
    };

    subtest 'B14: a child that drops the client leaves the parent connected' => sub {
        parent_survives(sub { undef $_[0]; exit 0 });
    };

    subtest 'control: a child that skips destructors' => sub {
        parent_survives(sub { POSIX::_exit(0) });
    };
}

done_testing;
