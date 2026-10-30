# t/10-connection/fork-inflight.t
#
# Work in flight when the process forks. The child inherits the parent's
# event loop, with every watch and timer the parent registered; whatever
# the child's loop does, the parent's work stays the parent's, and the
# child never acts on the parent's socket.
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis inject_eof redis_host);
use Test2::V0;
use Async::Redis;
use Future::IO;
use POSIX qw(_exit);

plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';

my $check = skip_without_redis();

# Run the block in a forked child and return the single line it produced
# (or "DIED: ..."). The parent blocks in waitpid, so it reads nothing
# while the child runs.
sub in_child (&) {
    my ($code) = @_;
    pipe(my $from_child, my $to_child) or die "pipe: $!";
    my $pid = fork() // die "fork failed: $!";
    if ($pid == 0) {
        close $from_child;
        my $line = eval { $code->() } // "DIED: $@";
        $line =~ s/\n/ /g;
        print $to_child "$line\n";
        close $to_child;
        _exit(0);
    }
    close $to_child;
    waitpid($pid, 0);
    my $line = <$from_child> // '';
    chomp $line;
    return $line;
}

# Run the child's (inherited) event loop for $secs.
sub child_runs_loop {
    my ($secs) = @_;
    run { Future::IO->sleep($secs) };
}

sub fresh_client { Async::Redis->new(host => redis_host(), @_) }

subtest 'a command not yet written at fork runs once' => sub {
    for my $ap (0, 1) {
        run { $check->del('fi:cnt') };
        my $r = fresh_client(auto_pipeline => $ap);
        run { $r->connect };
        my $incr = $r->incr('fi:cnt');                  # the loop has not run yet
        in_child { child_runs_loop(0.5); 'ok' };
        settle($incr, 3);
        is run { $check->get('fi:cnt') }, 1, "server ran it once (auto_pipeline=$ap)";
        is $incr->is_done ? $incr->get : failure_of($incr), 1, 'the parent got its reply';
        is run { $r->ping }, 'PONG', 'the parent connection still works';
        $r->disconnect;
    }
};

subtest 'a pipeline executed at fork runs once' => sub {
    run { $check->del('fi:p') };
    my $r = fresh_client();
    run { $r->connect };
    my $p = $r->pipeline;
    $p->incr('fi:p');
    $p->incr('fi:p');
    my $done = $p->execute;
    in_child { child_runs_loop(0.5); 'ok' };
    settle($done, 3);
    is run { $check->get('fi:p') }, 2, 'two INCRs, not four';
    $r->disconnect;
};

subtest 'a reply pending at fork reaches the parent' => sub {
    run { $check->del('fi:none') };
    my $r = fresh_client();
    run { $r->connect };
    my $blpop = $r->command('BLPOP', 'fi:none', '1');
    run { Future::IO->sleep(0.05) };                     # written; reply due in 1s
    in_child { child_runs_loop(2); 'ok' };
    is settle($blpop, 3), 'done', 'BLPOP completes in the parent';
    $r->disconnect;
};

subtest 'a subscribed parent receives messages while the child runs its loop' => sub {
    my $r = fresh_client();
    run { $r->connect };
    my $sub = run { $r->subscribe('fi:chan') };
    in_child {
        my $pub = fresh_client();                       # the child's own connection
        run { $pub->connect };
        run { $pub->publish('fi:chan', 'hello') };
        child_runs_loop(0.5);
        'ok';
    };
    my $next = $sub->next;
    is settle($next, 2), 'done', 'a message arrived';
    is $next->is_done ? $next->get->{data} : undef, 'hello', 'the published one';
    $r->disconnect;
};

run { $check->del('fi:cnt', 'fi:p', 'fi:none') };

done_testing;
