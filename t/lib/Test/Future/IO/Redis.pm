package Test::Future::IO::Redis;

use strict;
use warnings;
use Exporter 'import';
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Process;
use Future::IO;
use Future::IO::Redis;

# For testing, we use IO::Async as our concrete event loop.
# Production code can use any Future::IO-compatible loop (UV, Glib, etc.)
Future::IO->load_impl('IOAsync');

our @EXPORT_OK = qw(
    init_loop
    get_loop
    await_f
    skip_without_redis
    cleanup_keys
    cleanup_keys_async
    with_timeout
    fails_with
    delay
    run_command_async
    run_docker_async
    measure_ticks
    redis_host
    redis_port
);

our $loop;

# Get Redis connection details from environment
sub redis_host { $ENV{REDIS_HOST} // 'localhost' }
sub redis_port { $ENV{REDIS_PORT} // 6379 }

# Initialize the event loop (call once at test start)
sub init_loop {
    $loop = IO::Async::Loop->new;
    return $loop;
}

# Get the current loop
sub get_loop {
    $loop //= init_loop();
    return $loop;
}

# Await a future and return its result
sub await_f {
    my ($f) = @_;
    get_loop()->await($f);
    return $f->get;
}

# Skip if no Redis available
sub skip_without_redis {
    my $redis = eval {
        my $r = Future::IO::Redis->new(
            host => redis_host(),
            port => redis_port(),
            connect_timeout => 2,
        );
        get_loop()->await($r->connect);
        $r;
    };
    return $redis if $redis;
    skip_all("Redis not available at " . redis_host() . ":" . redis_port() . ": $@");
}

# Clean up test keys - blocking version (use in cleanup only)
sub cleanup_keys {
    my ($redis, $pattern) = @_;
    eval {
        get_loop()->await(_cleanup_keys_impl($redis, $pattern));
    };
}

# Clean up test keys - async version (preferred)
sub cleanup_keys_async {
    my ($redis, $pattern) = @_;
    return _cleanup_keys_impl($redis, $pattern);
}

sub _cleanup_keys_impl {
    my ($redis, $pattern) = @_;
    return $redis->keys($pattern)->then(sub {
        my ($keys) = @_;
        return Future->done unless @$keys;
        return $redis->del(@$keys);
    });
}

# Test with timeout wrapper
sub with_timeout {
    my ($timeout, $future) = @_;
    my $timeout_f = Future::IO->sleep($timeout)->then(sub {
        Future->fail("Test timeout after ${timeout}s");
    });
    return Future->wait_any($future, $timeout_f);
}

# Assert Future fails with specific error type (blocking)
sub fails_with {
    my ($future, $error_class, $message) = @_;
    my $error;
    eval { get_loop()->await($future); 1 } or $error = $@;
    ok($error && ref($error) && $error->isa($error_class), $message)
        or diag("Expected $error_class, got: " . (ref($error) || $error // 'undef'));
}

# Async delay - use instead of sleep()!
sub delay {
    my ($seconds) = @_;
    return Future::IO->sleep($seconds);
}

# Run external command asynchronously
sub run_command_async {
    my (@cmd) = @_;
    my $future = get_loop()->new_future;
    my $stdout = '';
    my $stderr = '';

    my $process = IO::Async::Process->new(
        command => \@cmd,
        stdout => { into => \$stdout },
        stderr => { into => \$stderr },
        on_finish => sub {
            my ($self, $exitcode) = @_;
            if ($exitcode == 0) {
                $future->done($stdout);
            } else {
                $future->fail("Command [@cmd] failed (exit $exitcode): $stderr");
            }
        },
    );

    get_loop()->add($process);
    return $future;
}

# Docker-specific helper
sub run_docker_async {
    my (@args) = @_;
    return run_command_async('docker', @args);
}

# Measure event loop ticks during an operation
# Returns ($result, $tick_count)
sub measure_ticks {
    my ($future, $interval) = @_;
    $interval //= 0.01;  # 10ms default

    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => $interval,
        on_tick => sub { push @ticks, time() },
    );
    get_loop()->add($timer);
    $timer->start;

    my $result_f = $future->then(sub {
        my (@result) = @_;
        $timer->stop;
        get_loop()->remove($timer);
        return Future->done(\@result, scalar(@ticks));
    })->catch(sub {
        my ($error) = @_;
        $timer->stop;
        get_loop()->remove($timer);
        return Future->fail($error);
    });

    return $result_f;
}

1;

__END__

=head1 NAME

Test::Future::IO::Redis - Test utilities for Future::IO::Redis

=head1 SYNOPSIS

    use lib 't/lib';
    use Test::Future::IO::Redis qw(
        init_loop skip_without_redis await_f delay cleanup_keys
    );

    my $loop = init_loop();
    my $redis = skip_without_redis();

    # Use await_f for simple awaits
    my $result = await_f($redis->get('key'));

    # Cleanup
    cleanup_keys($redis, 'test:*');

=head1 DESCRIPTION

Test utilities for Future::IO::Redis that maintain async discipline.

=head1 FUNCTIONS

=over 4

=item init_loop()

Initialize and return the IO::Async::Loop.

=item get_loop()

Get the current loop (initializes if needed).

=item await_f($future)

Await a future and return its result.

=item skip_without_redis()

Skip all tests if Redis is not available. Returns a connected
Future::IO::Redis object if successful.

=item cleanup_keys($redis, $pattern)

Delete all keys matching pattern.

=item with_timeout($seconds, $future)

Wrap a future with a timeout.

=item fails_with($future, $error_class, $message)

Assert that a future fails with the specified error class.

=item delay($seconds)

Return a future that resolves after the specified delay.

=item run_command_async(@cmd)

Run an external command asynchronously.

=item run_docker_async(@args)

Run a docker command asynchronously.

=item measure_ticks($future, $interval)

Measure event loop ticks during a future's execution.

=back

=cut
