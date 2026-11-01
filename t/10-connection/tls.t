# t/10-connection/tls.t
use strict;
use warnings;
use Test::Lib;
use Test::Async::Redis ':redis', 'settle', 'failure_of';
use Test2::V0;
use Async::Redis;
use Time::HiRes qw(time);

# Helper: await a Future and return its result (throws on failure)

subtest 'TLS module availability' => sub {
    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    ok(1, "IO::Socket::SSL " . ($has_ssl ? "available" : "not available"));
};

subtest 'constructor accepts TLS parameters' => sub {
    my $redis = Async::Redis->new(
        host => 'localhost',
        tls  => 1,
    );

    is($redis->{tls}, 1, 'tls enabled');
};

subtest 'TLS with options hash' => sub {
    my $redis = Async::Redis->new(
        host => 'localhost',
        tls  => {
            ca_file   => '/path/to/ca.crt',
            cert_file => '/path/to/client.crt',
            key_file  => '/path/to/client.key',
            verify    => 1,
        },
    );

    is(ref $redis->{tls}, 'HASH', 'tls is hash');
    is($redis->{tls}{ca_file}, '/path/to/ca.crt', 'ca_file stored');
};

subtest 'rediss URI enables TLS' => sub {
    my $redis = Async::Redis->new(
        uri => 'rediss://localhost:6380',
    );

    ok($redis->{tls}, 'TLS enabled from rediss://');
};

SKIP: {
    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    skip "IO::Socket::SSL not available", 1 unless $has_ssl;

    subtest 'TLS without server fails gracefully' => sub {
        my $redis = Async::Redis->new(
            host            => 'localhost',
            port            => 16380,  # unlikely to have TLS Redis here
            tls             => 1,
            connect_timeout => 1,
        );

        my $error;
        eval { $redis->connect->get };
        $error = $@;

        ok($error, 'connection failed (expected - no TLS server)');
    };
}

# TLS tests with actual TLS Redis require specific setup
SKIP: {
    skip "Set TLS_REDIS_HOST and TLS_REDIS_PORT to test TLS", 5
        unless $ENV{TLS_REDIS_HOST} && $ENV{TLS_REDIS_PORT};

    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    skip "IO::Socket::SSL not available", 5 unless $has_ssl;

    subtest 'TLS connection works' => sub {
        my $redis = Async::Redis->new(
            host => $ENV{TLS_REDIS_HOST},
            port => $ENV{TLS_REDIS_PORT},
            tls  => {
                verify => 0,  # skip verification for testing
            },
        );

        run { $redis->connect };
        my $pong = run { $redis->ping };
        is($pong, 'PONG', 'TLS connection works');

        $redis->disconnect;
    };

    subtest 'TLS non-blocking verification' => sub {
        my $redis = Async::Redis->new(
            host            => $ENV{TLS_REDIS_HOST},
            port            => $ENV{TLS_REDIS_PORT},
            tls             => { verify => 0 },
            connect_timeout => 5,
        );

        run { $redis->connect };

        my @futures = map { $redis->set("nb:tls:$_", $_) } (1..50);
        my $start = time();
        run { Future->needs_all(@futures) };
        my $elapsed = time() - $start;
        ok($elapsed < 5, "50 concurrent ops completed in ${elapsed}s");
        run { $redis->del(map { "nb:tls:$_" } 1..50) };

        $redis->disconnect;
    };

    subtest 'TLS with auth works' => sub {
        plan skip_all => "Set TLS_REDIS_PASS to test TLS+auth"
            unless $ENV{TLS_REDIS_PASS};

        my $redis = Async::Redis->new(
            host     => $ENV{TLS_REDIS_HOST},
            port     => $ENV{TLS_REDIS_PORT},
            tls      => { verify => 0 },
            password => $ENV{TLS_REDIS_PASS},
        );

        run { $redis->connect };
        my $pong = run { $redis->ping };
        is($pong, 'PONG', 'TLS + auth works');

        $redis->disconnect;
    };

    # The test server's certificate is self-signed, so verification
    # (the default) must refuse it.
    subtest 'verification on rejects the self-signed server' => sub {
        my $redis = Async::Redis->new(
            host            => $ENV{TLS_REDIS_HOST},
            port            => $ENV{TLS_REDIS_PORT},
            tls             => 1,
            connect_timeout => 3,
        );
        my $t0 = time();
        my $f  = $redis->connect;
        is settle($f, 4), 'failed', 'the connect fails';
        ok time() - $t0 < 4, 'promptly';
        my $e = failure_of($f);
        isa_ok $e, 'Async::Redis::Error::Connection';
        like "$e", qr/certificate|verif/i, 'naming the certificate problem';
    };

    subtest 'a large value round-trips over TLS' => sub {
        my $redis = Async::Redis->new(
            host => $ENV{TLS_REDIS_HOST},
            port => $ENV{TLS_REDIS_PORT},
            tls  => { verify => 0 },
        );
        run { $redis->connect };
        my $value = join '', map { chr(65 + $_ % 26) } 1 .. 200_000;
        run { $redis->set('tls:big', $value) };
        my $got = run { $redis->get('tls:big') };
        is length($got // ''), 200_000, 'all of it arrives';
        ok defined $got && $got eq $value, 'intact';
        run { $redis->del('tls:big') };
        $redis->disconnect;
    };
}

done_testing;
