#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

# Load Future::IO implementation - MUST load IO::Async::Loop first
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;

use lib 'lib';
use Future::IO::Redis;

# Skip if no Redis available
my $redis_host = $ENV{REDIS_HOST} // 'localhost';
my $redis_port = $ENV{REDIS_PORT} // 6379;

plan skip_all => 'Set REDIS_HOST to run tests'
    unless $ENV{REDIS_HOST} || `docker ps 2>/dev/null` =~ /redis/;

my $loop = IO::Async::Loop->new;

# Helper to run async code in tests
sub run_async (&) {
    my ($code) = @_;
    my $f = $code->();
    return $f->get;  # Block until done and return result
}

my $redis;

subtest 'connect to Redis' => sub {
    $redis = Future::IO::Redis->new(
        host => $redis_host,
        port => $redis_port,
    );

    my $result = eval {
        run_async { $redis->connect };
    };

    ok !$@, 'connected without error' or diag $@;
    ok $redis->{connected}, 'connected flag is set';
};

subtest 'PING' => sub {
    my $pong = run_async { $redis->ping };
    is $pong, 'PONG', 'PING returns PONG';
};

subtest 'SET and GET' => sub {
    run_async { $redis->set('test:key', 'hello') };
    my $value = run_async { $redis->get('test:key') };

    is $value, 'hello', 'GET returns SET value';

    # Cleanup
    run_async { $redis->del('test:key') };
};

subtest 'SET with expiry' => sub {
    run_async { $redis->set('test:expiry', 'temp', ex => 10) };
    my $value = run_async { $redis->get('test:expiry') };

    is $value, 'temp', 'GET returns value before expiry';

    run_async { $redis->del('test:expiry') };
};

subtest 'INCR' => sub {
    run_async { $redis->set('test:counter', 0) };
    my $v1 = run_async { $redis->incr('test:counter') };
    my $v2 = run_async { $redis->incr('test:counter') };
    my $v3 = run_async { $redis->incr('test:counter') };

    is $v1, 1, 'first INCR returns 1';
    is $v2, 2, 'second INCR returns 2';
    is $v3, 3, 'third INCR returns 3';

    run_async { $redis->del('test:counter') };
};

subtest 'list operations' => sub {
    run_async { $redis->del('test:list') };
    run_async { $redis->rpush('test:list', 'a', 'b', 'c') };

    my $list = run_async { $redis->lrange('test:list', 0, -1) };
    is $list, ['a', 'b', 'c'], 'LRANGE returns all elements';

    my $popped = run_async { $redis->lpop('test:list') };
    is $popped, 'a', 'LPOP returns first element';

    run_async { $redis->del('test:list') };
};

subtest 'NULL handling' => sub {
    my $value = run_async { $redis->get('nonexistent:key:12345') };
    is $value, undef, 'GET nonexistent key returns undef';
};

subtest 'disconnect' => sub {
    $redis->disconnect;
    ok !$redis->{connected}, 'disconnected';
};

done_testing;
