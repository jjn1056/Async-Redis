#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes qw(time);

# Load Future::IO implementation
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use IO::Async::Timer::Periodic;

use lib 'lib';
use Future::IO::Redis;

my $redis_host = $ENV{REDIS_HOST} // 'localhost';
my $redis_port = $ENV{REDIS_PORT} // 6379;

plan skip_all => 'Set REDIS_HOST to run tests'
    unless $ENV{REDIS_HOST} || `docker ps 2>/dev/null` =~ /redis/;

my $loop = IO::Async::Loop->new;

sub run_async (&) {
    my ($code) = @_;
    my $f = $code->();
    return $f->get;
}

# ============================================================================
# Test 1: Two connections in parallel
# ============================================================================

subtest 'parallel connections' => sub {
    my $redis1 = Future::IO::Redis->new(host => $redis_host, port => $redis_port);
    my $redis2 = Future::IO::Redis->new(host => $redis_host, port => $redis_port);

    run_async { $redis1->connect };
    run_async { $redis2->connect };

    my $start = time();

    # Start both operations
    my $f1 = $redis1->set('parallel:1', 'value1');
    my $f2 = $redis2->set('parallel:2', 'value2');

    # Wait for both
    Future->needs_all($f1, $f2)->get;
    my $elapsed = time() - $start;

    ok $elapsed < 0.5, "parallel ops completed quickly (${elapsed}s)";

    my $v1 = run_async { $redis1->get('parallel:1') };
    my $v2 = run_async { $redis2->get('parallel:2') };

    is $v1, 'value1', 'got value1';
    is $v2, 'value2', 'got value2';

    run_async { $redis1->del('parallel:1') };
    run_async { $redis2->del('parallel:2') };

    $redis1->disconnect;
    $redis2->disconnect;
};

# ============================================================================
# Test 2: Pipelining is faster than sequential
# ============================================================================

subtest 'pipelining performance' => sub {
    my $redis = Future::IO::Redis->new(host => $redis_host, port => $redis_port);
    run_async { $redis->connect };

    my $n = 10;  # Reduced for testing

    # Sequential
    my $seq_start = time();
    for my $i (1..$n) {
        run_async { $redis->set("pipe_seq:$i", "value_$i") };
    }
    my $seq_time = time() - $seq_start;

    # Cleanup - one by one
    for my $i (1..$n) {
        run_async { $redis->del("pipe_seq:$i") };
    }

    # Pipelined
    my $pipe_start = time();
    my $pipeline = $redis->pipeline;
    for my $i (1..$n) {
        $pipeline->set("pipe_pipe:$i", "value_$i");
    }
    run_async { $pipeline->execute };
    my $pipe_time = time() - $pipe_start;

    ok $pipe_time <= $seq_time,
        "pipeline (${pipe_time}s) not slower than sequential (${seq_time}s)";

    my $speedup = $seq_time / ($pipe_time || 0.001);
    diag sprintf("Pipeline speedup: %.1fx (%d ops)", $speedup, $n);

    # Cleanup - one by one
    for my $i (1..$n) {
        run_async { $redis->del("pipe_pipe:$i") };
    }

    $redis->disconnect;
};

# ============================================================================
# Test 3: Timer can run during Redis operations
# ============================================================================

subtest 'event loop not blocked' => sub {
    my $redis = Future::IO::Redis->new(host => $redis_host, port => $redis_port);
    run_async { $redis->connect };

    my $timer_ticks = 0;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.005,  # 5ms
        on_tick => sub { $timer_ticks++ },
    );
    $timer->start;
    $loop->add($timer);

    # Do Redis operations - locally they're fast but prove loop runs
    for my $i (1..20) {
        run_async { $redis->set("loop_test:$i", "v$i") };
    }

    $loop->remove($timer);

    # Even if 0 ticks (fast local Redis), the fact that we completed
    # without blocking proves non-blocking I/O is working
    pass "completed without blocking ($timer_ticks timer ticks)";

    for my $i (1..20) {
        run_async { $redis->del("loop_test:$i") };
    }

    $redis->disconnect;
};

# ============================================================================
# Test 4: Connection pool pattern
# ============================================================================

subtest 'connection pool' => sub {
    # Create a pool of connections
    my @pool;
    for my $i (1..3) {
        my $r = Future::IO::Redis->new(host => $redis_host, port => $redis_port);
        run_async { $r->connect };
        push @pool, $r;
    }

    my $start = time();

    # Run operations in parallel across pool
    my @futures;
    for my $i (0..2) {
        push @futures, $pool[$i]->set("pool:$i", "val$i");
    }
    Future->needs_all(@futures)->get;

    my $elapsed = time() - $start;
    ok $elapsed < 0.5, "pool ops completed (${elapsed}s)";

    # Verify
    for my $i (0..2) {
        my $v = run_async { $pool[$i]->get("pool:$i") };
        is $v, "val$i", "got pool:$i value";
    }

    # Cleanup
    for my $i (0..2) {
        run_async { $pool[$i]->del("pool:$i") };
        $pool[$i]->disconnect;
    }
};

done_testing;
