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
use Future;
use Future::AsyncAwait;
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

# Run the child's (inherited) event loop for $secs, idle unless something
# in it fires. (run { } would busy-wait on sleep(0) instead.)
sub child_runs_loop {
    my ($secs) = @_;
    Future::IO->sleep($secs)->get;
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

subtest 'inherited commands fail in the child with the forked error' => sub {
    my ($disc, $err) = (0, 0);
    my $r = fresh_client(on_disconnect => sub { $disc++ }, on_error => sub { $err++ });
    run { $r->connect };
    run { $r->del('fi:none') };
    my $blpop = $r->command('BLPOP', 'fi:none', '2');
    run { Future::IO->sleep(0.05) };
    my $line = in_child {
        my @warn;
        local $SIG{__WARN__} = sub { push @warn, @_ };
        $r->is_connected;                               # the child's first call
        my $state = $blpop->is_failed ? 'failed' : $blpop->is_done ? 'done' : 'pending';
        my $e = failure_of($blpop);
        my $line = sprintf "%s|%s|%s|disc=%d err=%d warn=%d", $state,
            ref($e) // '', ("" . ($e // '')) =~ s/\n.*//sr, $disc, $err, scalar @warn;
        $line . ' ping=' . run { $r->ping };
    };
    like $line, qr/^failed\|Async::Redis::Error::Disconnected\|.*fork.*\|disc=0 err=0 warn=0 ping=PONG$/,
        'Disconnected naming the fork; no callbacks, no warnings; the child\'s own command works';
    is settle($blpop, 4), 'done', 'the parent BLPOP is untouched';
    $r->disconnect;
};

subtest 'auto-pipelined commands queued at fork fail in the child' => sub {
    my $r = fresh_client(auto_pipeline => 1);
    run { $r->connect };
    my $get = $r->get('fi:x');                          # queued; flush not yet run
    my $line = in_child {
        $r->is_connected;
        $get->is_failed ? 'failed: ' . (failure_of($get) =~ s/\n.*//sr) : 'not failed';
    };
    like $line, qr/^failed: .*fork/, 'the queued command fails with the forked error';
    settle($get, 2);
    $r->disconnect;
};

subtest 'a multi() running at fork does not block one in the child' => sub {
    my $r = fresh_client();
    run { $r->connect };
    my $gate = Future->new;
    my $tx = $r->multi(async sub { await $gate; $_[0]->ping });
    my $line = in_child {
        my $res = run { $r->multi(async sub { $_[0]->ping }) };
        'got ' . join ',', @$res;
    };
    is $line, 'got PONG', 'the child runs its own transaction';
    $gate->done;
    is settle($tx, 2), 'done', 'the parent transaction completes';
    $r->disconnect;
};

subtest 'a child that declines a read does not spin' => sub {
    my $r = fresh_client();
    run { $r->connect };
    my $sub = run { $r->subscribe('fi:spin') };
    my $line = in_child {
        my $pub = fresh_client();
        run { $pub->connect };
        run { $pub->publish('fi:spin', 'x') };          # makes the shared socket readable
        my $t0 = (times)[0];
        child_runs_loop(1);
        sprintf 'cpu %.2f', (times)[0] - $t0;
    };
    my ($cpu) = $line =~ /cpu ([\d.]+)/;
    # A spinning loop uses close to the whole second.
    ok defined $cpu && $cpu < 0.3, "the child used little CPU ($line)";
    $r->disconnect;
};

run { $check->del('fi:cnt', 'fi:p', 'fi:none') };

done_testing;
