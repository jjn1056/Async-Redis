# t/10-connection/fork-inflight.t
#
# Work in flight when the process forks. The child inherits the parent's
# event loop, with every watch and timer the parent registered; whatever
# the child's loop does, the parent's work stays the parent's, and the
# child never acts on the parent's socket.
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of skip_without_redis inject_eof redis_host with_timeout);
use Test2::V0;
use Async::Redis;
use Future;
use Future::AsyncAwait;
use Future::IO;
use POSIX qw(_exit);
use IO::Socket::INET;
use Time::HiRes ();

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

subtest 'an inherited subscription fails in the child' => sub {
    my $r = fresh_client();
    run { $r->connect };
    my $sub = run { $r->subscribe('fi:c2') };
    my $line = in_child {
        # No message is ever published; give up after 2s.
        my $ok = eval { run { with_timeout(2, $sub->next) }; 1 };
        $ok ? 'returned' : 'failed: ' . ("$@" =~ s/\n.*//sr);
    };
    like $line, qr/^failed: .*fork/, 'next() fails with the forked error';
    $r->disconnect;
};

subtest 'callback-mode on_error is called once in the child, no warning' => sub {
    my $r = fresh_client();
    run { $r->connect };
    my $sub = run { $r->subscribe('fi:c3') };
    my @errors;
    $sub->on_message(sub {});
    $sub->on_error(sub { push @errors, $_[1] });
    my $line = in_child {
        my @warn;
        local $SIG{__WARN__} = sub { push @warn, @_ };
        $r->is_connected;
        $r->is_connected;
        sprintf 'errors=%d warn=%d %s', scalar @errors, scalar @warn,
            ("" . ($errors[0] // '')) =~ s/\n.*//sr;
    };
    like $line, qr/^errors=1 warn=0 .*fork/, 'on_error once, with the forked error';
    $r->disconnect;
};

# client_name makes the handshake send CLIENT SETNAME, so a connect that
# resumed in the child would write to the socket.

subtest 'a connect in progress at fork completes in the parent' => sub {
    my $r = fresh_client(client_name => 'fi-parent');
    my $c = $r->connect;                                # in progress
    my $line = in_child {
        child_runs_loop(0.5);
        my $e = failure_of($c);
        sprintf '%s %s', ref($e) // '', ("" . ($e // 'not failed')) =~ s/\n.*//sr;
    };
    like $line, qr/^Async::Redis::Error::Disconnected .*fork/,
        'in the child the inherited attempt fails with the forked error';
    is settle($c, 3), 'done', 'the parent connect completes';
    is run { $r->ping }, 'PONG', 'and the connection works';
    $r->disconnect;
};

# A port nothing listens on: a non-blocking connect to it is still in
# progress when connect() returns, and fails when the socket is polled.
sub refusing_port {
    my $listener = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1')
        or die "listen: $!";
    my $port = $listener->sockport;
    close $listener;
    return $port;
}

subtest 'a connect being refused at fork fails in the parent' => sub {
    my $r = fresh_client(host => '127.0.0.1', port => refusing_port());
    my $c = $r->connect;
    plan skip_all => 'this system refuses a loopback connect at once, so it is never in progress at fork'
        if $c->is_ready;
    in_child { child_runs_loop(0.5); 'ok' };
    is settle($c, 3), 'failed', 'the parent connect fails';
    like failure_of($c) // '', qr/refused/i, 'refused, as without the fork';
};

subtest 'a child whose connect was inherited makes its own' => sub {
    my $r = fresh_client(client_name => 'fi-parent');
    my $c = $r->connect;
    my $line = in_child {
        run { $r->connect };
        'connected ' . $r->is_connected . ' id ' . run { $r->client('ID') };
    };
    is settle($c, 3), 'done', 'the parent connect completes';
    my $parent_id = run { $r->client('ID') };
    like $line, qr/^connected 1 id \d+$/, 'the child is connected' or diag $line;
    unlike $line, qr/ id $parent_id$/, 'on a connection of its own';
    $r->disconnect;
};

# Drop $r's connection the way a server going away does: the reader sees
# EOF while a command is in flight.
sub drop_connection {
    my ($r) = @_;
    my $blpop = $r->command('BLPOP', 'fi:none', '5');
    run { Future::IO->sleep(0.05) };
    inject_eof($r);
    settle($blpop, 1);
}

subtest 'a command waiting on a reconnect at fork runs once' => sub {
    run { $check->del('fi:rc', 'fi:none') };
    my $r = fresh_client(reconnect => 1);
    run { $r->connect };
    drop_connection($r);
    my $incr = $r->incr('fi:rc');                       # waits on the reconnect
    in_child { child_runs_loop(1); 'ok' };
    is settle($incr, 3), 'done', 'the parent command completes';
    is run { $check->get('fi:rc') }, 1, 'the server ran it once';
    $r->disconnect;
};

subtest 'a command waiting out a reconnect backoff at fork runs once' => sub {
    run { $check->del('fi:rc', 'fi:none') };
    my @errors;
    my $r = fresh_client(
        reconnect        => 1,
        reconnect_delay  => 0.5,
        reconnect_jitter => 0,
        on_error         => sub { push @errors, $_[1] },
    );
    run { $r->connect };
    drop_connection($r);

    # Redis is unreachable for the first attempt, and back by the retry.
    my $refusing = refusing_port();
    my ($host, $port) = @{$r}{qw(host port)};
    @{$r}{qw(host port)} = ('127.0.0.1', $refusing);
    my $incr = $r->incr('fi:rc');
    # Wait for the first attempt to fail (about 30ms here); the retry is
    # due 0.5s after that.
    my $until = Time::HiRes::time() + 2;
    run { Future::IO->sleep(0.01) } while !@errors && Time::HiRes::time() < $until;
    @{$r}{qw(host port)} = ($host, $port);
    is scalar @errors, 1, 'in backoff when the process forks';

    my $line = in_child {
        child_runs_loop(1.5);
        'errors=' . scalar(@errors) . ' connected=' . $r->is_connected;
    };
    is $line, 'errors=1 connected=0',
        'the child neither reports nor retries the parent\'s attempt';
    is settle($incr, 3), 'done', 'the parent command completes';
    is run { $check->get('fi:rc') }, 1, 'the server ran it once';
    $r->disconnect;
};

subtest 'a multi() still collecting at fork sends nothing from the child' => sub {
    run { $check->del('fi:tx') };
    my $r = fresh_client();
    run { $r->connect };
    my $gate = Future->new;
    my $tx = $r->multi(async sub { await $gate; $_[0]->incr('fi:tx') });
    my $line = in_child {
        $gate->done;                                    # the callback finishes here
        child_runs_loop(0.5);
        my $e = failure_of($tx);
        ($tx->is_failed ? 'failed: ' . ("$e" =~ s/\n.*//sr) : 'not failed')
            . ' connected=' . $r->is_connected;
    };
    like $line, qr/^failed: .*fork.* connected=0$/,
        'in the child it fails with the forked error, having connected nowhere';
    $gate->done;
    is settle($tx, 3), 'done', 'the parent transaction completes';
    is run { $check->get('fi:tx') }, 1, 'the transaction ran once, in the parent';
    $r->disconnect;
};

subtest 'a watch_multi() still collecting at fork sends nothing from the child' => sub {
    run { $check->del('fi:wtx') };
    my $r = fresh_client();
    run { $r->connect };
    my $gate = Future->new;
    my $tx = $r->watch_multi(['fi:wtx'], async sub { await $gate; $_[0]->incr('fi:wtx') });
    run { Future::IO->sleep(0.05) };                    # WATCH and GET are done
    my $line = in_child {
        $gate->done;
        child_runs_loop(0.5);
        my $e = failure_of($tx);
        ($tx->is_failed ? 'failed: ' . ("$e" =~ s/\n.*//sr) : 'not failed')
            . ' connected=' . $r->is_connected;
    };
    like $line, qr/^failed: .*fork.* connected=0$/,
        'in the child it fails with the forked error, having connected nowhere';
    $gate->done;
    is settle($tx, 3), 'done', 'the parent transaction completes';
    # Had the child run it, the parent's EXEC would abort (WATCH) with undef.
    is $tx->is_done ? $tx->get : undef, [1], 'the parent\'s EXEC ran';
    is run { $check->get('fi:wtx') }, 1, 'the transaction ran once';
    $r->disconnect;
};

subtest 'disconnect in a child fires no on_disconnect' => sub {
    my $n = 0;
    my $r = fresh_client(on_disconnect => sub { $n++ });
    run { $r->connect };
    is in_child { $r->disconnect; "n=$n" }, 'n=0', 'not in the child';
    is run { $r->ping }, 'PONG', 'and the parent connection works';
    $r->disconnect;
    is $n, 1, 'the parent\'s own disconnect fires it';
};

subtest 'code run by a failing inherited command sees the child disconnected' => sub {
    my $r = fresh_client();
    run { $r->connect };
    run { $r->del('fi:none') };
    my $blpop = $r->command('BLPOP', 'fi:none', '2');
    run { Future::IO->sleep(0.05) };
    my ($seen, $retry);
    $blpop->on_fail(sub { $seen = $r->is_connected; $retry = $r->ping });
    my $line = in_child {
        $r->is_connected;
        my $res = eval { run { $retry } } // 'failed: ' . ("$@" =~ s/\n.*//sr);
        "connected=$seen retry=$res";
    };
    is $line, 'connected=0 retry=PONG', 'it sees no connection, and a retry makes one';
    is settle($blpop, 4), 'done', 'the parent BLPOP is untouched';
    $r->disconnect;
};

subtest 'a child whose loop failed an inherited connect makes its own on the next command' => sub {
    my $r = fresh_client(client_name => 'fi-parent');
    my $c = $r->connect;
    my $line = in_child {
        child_runs_loop(0.5);                           # the inherited attempt fails here
        my $id = eval { run { $r->client('ID') } } // 'failed: ' . ("$@" =~ s/\n.*//sr);
        "id=$id";
    };
    is settle($c, 3), 'done', 'the parent connect completes';
    my $parent_id = run { $r->client('ID') };
    like $line, qr/^id=\d+$/, 'the child\'s command succeeds' or diag $line;
    unlike $line, qr/^id=$parent_id$/, 'on a connection of its own';
    $r->disconnect;
};

subtest 'a subscribe waiting at fork fails in the child with the forked error' => sub {
    my $r = fresh_client();
    run { $r->connect };
    run { $r->del('fi:none') };
    my $blpop = $r->command('BLPOP', 'fi:none', '1');   # subscribe waits for it
    run { Future::IO->sleep(0.05) };
    my $sub_f = $r->subscribe('fi:c4');
    my $line = in_child {
        $r->is_connected;
        child_runs_loop(0.2);
        $sub_f->is_failed ? 'failed: ' . (failure_of($sub_f) =~ s/\n.*//sr)
            : $sub_f->is_done ? 'done' : 'pending';
    };
    like $line, qr/^failed: .*fork/, 'it fails naming the fork';
    is settle($sub_f, 3), 'done', 'the parent subscribe completes';
    $r->disconnect;
};

subtest 'an inherited watch_multi() ending in the child leaves the child\'s own alone' => sub {
    run { $check->del('fi:w1', 'fi:w2') };
    my $r = fresh_client();
    run { $r->connect };
    my $gate1 = Future->new;
    my $tx1 = $r->watch_multi(['fi:w1'], async sub { await $gate1; $_[0]->incr('fi:w1') });
    run { Future::IO->sleep(0.05) };                    # WATCH and GET are done
    my $line = in_child {
        $r->is_connected;
        my $gate2 = Future->new;
        my $tx2 = $r->watch_multi(['fi:w2'], async sub { await $gate2; $_[0]->incr('fi:w2') });
        child_runs_loop(0.2);                           # the child's own WATCH is in place
        my $before = $r->watching;
        $gate1->done;                                   # the inherited one ends here
        my $after = $r->watching;
        $gate2->done;
        my $res = eval { run { $tx2 } } // 'failed';
        sprintf 'watching %d/%d result=%s', $before, $after, ref $res ? "@$res" : $res;
    };
    is $line, 'watching 1/1 result=1', 'the child\'s WATCH survives and its transaction commits';
    $gate1->done;
    is settle($tx1, 3), 'done', 'the parent transaction completes';
    $r->disconnect;
};

run { $check->del('fi:cnt', 'fi:p', 'fi:none', 'fi:rc', 'fi:tx', 'fi:wtx', 'fi:w1', 'fi:w2') };

done_testing;
