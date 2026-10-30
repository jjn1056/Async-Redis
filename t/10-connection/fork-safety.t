# t/10-connection/fork-safety.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis', 'current_connection';
use Test2::V0;
use Async::Redis;
use POSIX qw(_exit);
use Time::HiRes ();

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
            reconnect => 1,
        );
        run { $r->connect };
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'connection tracks PID' => sub {
        ok(current_connection($redis)->pid, 'PID tracked');
        is(current_connection($redis)->pid, $$, 'PID matches current process');
    };

    subtest 'connection detects fork and reconnects' => sub {
        plan skip_all => 'fork() not supported on this platform'
            if $^O eq 'MSWin32';

        # Store a value
        run { $redis->set('fork:test', 'parent_value') };

        my $pipe_to_child;
        my $pipe_from_child;
        pipe($pipe_from_child, $pipe_to_child) or die "pipe: $!";

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child process
            close $pipe_from_child;

            # The redis connection should detect PID change and reconnect
            my $result;
            eval {
                $result = $redis->get('fork:test')->get;
            };

            if ($@) {
                print $pipe_to_child "ERROR: $@\n";
            }
            elsif (defined $result && $result eq 'parent_value') {
                print $pipe_to_child "SUCCESS\n";
            }
            else {
                print $pipe_to_child "WRONG: " . ($result // 'undef') . "\n";
            }

            close $pipe_to_child;
            _exit(0);
        }

        # Parent process
        close $pipe_to_child;

        # Wait for child
        waitpid($pid, 0);

        my $child_output = do { local $/; <$pipe_from_child> };
        close $pipe_from_child;

        like($child_output, qr/SUCCESS/, "child got correct value after fork: $child_output");
    };

    subtest 'pool detects fork and clears connections' => sub {
        plan skip_all => 'fork() not supported on this platform'
            if $^O eq 'MSWin32';

        require Async::Redis::Pool;

        my $pool = Async::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            min  => 1,
            max  => 3,
        );

        # Get a connection in parent
        my $conn1 = run { $pool->acquire };
        run { $conn1->set('fork:pool', 'pool_value') };
        $pool->release($conn1);

        # Check pool stats before fork
        my $stats_before = $pool->stats;
        ok($stats_before->{idle} >= 1, 'pool has idle connections before fork');

        my $pipe_to_child;
        my $pipe_from_child;
        pipe($pipe_from_child, $pipe_to_child) or die "pipe: $!";

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child process
            close $pipe_from_child;

            # After fork, pool should detect fork and clear connections
            # Check that _check_fork is called on acquire
            my $stats_after = $pool->stats;

            # Force fork check by accessing pool state
            $pool->_check_fork;

            # After fork check, pool should be empty
            my $stats_cleared = $pool->stats;

            if ($stats_cleared->{idle} == 0 && $stats_cleared->{active} == 0) {
                print $pipe_to_child "SUCCESS\n";
            }
            else {
                print $pipe_to_child "WRONG: idle=$stats_cleared->{idle} active=$stats_cleared->{active}\n";
            }

            close $pipe_to_child;
            _exit(0);
        }

        # Parent
        close $pipe_to_child;
        waitpid($pid, 0);

        my $child_output = do { local $/; <$pipe_from_child> };
        close $pipe_from_child;

        like($child_output, qr/SUCCESS/, "pool cleared after fork in child: $child_output");

        # Parent pool should still work
        my $conn2 = run { $pool->acquire };
        my $val = run { $conn2->get('fork:pool') };
        is($val, 'pool_value', 'parent pool still works after child fork');
        $pool->release($conn2);

        # Cleanup
        run { $redis->del('fork:pool') };
    };

    subtest 'parent connection still works after fork' => sub {
        plan skip_all => 'fork() not supported on this platform'
            if $^O eq 'MSWin32';

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child just exits
            _exit(0);
        }

        waitpid($pid, 0);

        # Parent connection should still work
        my $result = run { $redis->ping };
        is($result, 'PONG', 'parent connection works after fork');
    };

    # A forked child has no connection of its own yet. Whatever reconnect
    # is set to, its first use of the client makes one; the parent's is
    # left alone. These run with reconnect off, the default.

    # Run $code in a forked child and return the line it produced.
    my $in_child = sub {
        my ($code) = @_;
        pipe(my $from_child, my $to_child) or die "pipe: $!";
        my $pid = fork() // die "fork failed: $!";
        if ($pid == 0) {
            close $from_child;
            my $line = eval { $code->() } // "DIED: $@";
            print $to_child "$line\n";
            close $to_child;
            _exit(0);
        }
        close $to_child;
        waitpid($pid, 0);
        my $line = <$from_child> // '';
        chomp $line;
        return $line;
    };

    my $plain = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    run { $plain->connect };
    my $parent_id = run { $plain->client('ID') };

    subtest 'reconnect off: a child\'s first command connects' => sub {
        plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';
        my $line = $in_child->(sub { 'got ' . run { $plain->ping } });
        is($line, 'got PONG', 'the child\'s command succeeds');
        is(run { $plain->ping }, 'PONG', 'the parent still works');
    };

    subtest 'reconnect off: connect() in a child makes a new connection' => sub {
        plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';
        my $line = $in_child->(sub {
            run { $plain->connect };
            my $connected = $plain->is_connected;
            "connected $connected id " . run { $plain->client('ID') };
        });
        like($line, qr/^connected 1 id \d+$/, 'connect() itself connects the child')
            or diag $line;
        unlike($line, qr/ id $parent_id$/, 'on a connection of its own');
        is(run { $plain->client('ID') }, $parent_id, 'the parent keeps its connection');
    };

    subtest 'is_connected in a child does not report the parent\'s connection' => sub {
        plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';
        my $line = $in_child->(sub { 'is_connected ' . $plain->is_connected });
        is($line, 'is_connected 0', 'not connected before the child connects');
    };

    subtest 'reconnect off: a child that disconnects stays disconnected' => sub {
        plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';
        my $line = $in_child->(sub {
            $plain->is_connected;        # notices the fork first
            $plain->disconnect;
            my $ok = eval { run { $plain->ping }; 1 };
            $ok ? 'connected' : "failed: $@";
        });
        like($line, qr/^failed: .*Not connected/, 'a deliberate disconnect is respected')
            or diag $line;
        is(run { $plain->ping }, 'PONG', 'the parent still works');
    };

    subtest 'subscribe in a child does not wait on the parent\'s commands' => sub {
        plan skip_all => 'fork() not supported on this platform' if $^O eq 'MSWin32';
        run { $plain->del('fork:none') };
        my $blpop = $plain->command('BLPOP', 'fork:none', '2');   # in flight at the fork
        my $line = $in_child->(sub {
            my $t0 = Time::HiRes::time();
            my $ok = eval { run { $plain->subscribe('fork:chan') }; 1 };
            my $took = Time::HiRes::time() - $t0;
            sprintf "%s after %.1fs", ($ok ? 'subscribed' : "failed: $@" =~ s/\n.*//sr), $took;
        });
        like($line, qr/^failed: .*Not connected.* after 0\.\ds$/,
            'it fails at once, like any client that is not connected')
            or diag $line;
        my $settled = eval { run { $blpop }; 1 } ? 'done' : 'failed';
        is($settled, 'done', 'the parent\'s command completes');
    };

    $plain->disconnect;

    # Cleanup
    run { $redis->del('fork:test') };
    $redis->disconnect;
}

done_testing;
