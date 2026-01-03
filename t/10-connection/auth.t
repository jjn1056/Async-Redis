# t/10-connection/auth.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

# Helper: await a Future and return its result (throws on failure)
sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

subtest 'constructor accepts auth parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host        => 'localhost',
        password    => 'secret',
        username    => 'myuser',
        database    => 5,
        client_name => 'myapp',
    );

    is($redis->{password}, 'secret', 'password stored');
    is($redis->{username}, 'myuser', 'username stored');
    is($redis->{database}, 5, 'database stored');
    is($redis->{client_name}, 'myapp', 'client_name stored');
};

subtest 'URI parsed for auth' => sub {
    my $redis = Future::IO::Redis->new(
        uri => 'redis://user:pass@localhost:6380/3',
    );

    is($redis->{username}, 'user', 'username from URI');
    is($redis->{password}, 'pass', 'password from URI');
    is($redis->{database}, 3, 'database from URI');
    is($redis->{host}, 'localhost', 'host from URI');
    is($redis->{port}, 6380, 'port from URI');
};

subtest 'URI TLS detected' => sub {
    my $redis = Future::IO::Redis->new(
        uri => 'rediss://localhost',
    );

    ok($redis->{tls}, 'TLS enabled from rediss://');
};

# Tests requiring Redis with specific configuration
SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 3 unless $test_redis;
    $test_redis->disconnect;

    subtest 'SELECT database works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_HOST} // 'localhost',
            database => 1,
        );

        await_f($redis->connect);

        # Set a key in database 1
        await_f($redis->set('auth:test:db1', 'value1'));

        # Verify we're in database 1
        my $val = await_f($redis->get('auth:test:db1'));
        is($val, 'value1', 'key accessible in db 1');

        await_f($redis->del('auth:test:db1'));
        $redis->disconnect;

        # Connect to database 0, key should not exist
        my $redis2 = Future::IO::Redis->new(
            host     => $ENV{REDIS_HOST} // 'localhost',
            database => 0,
        );
        await_f($redis2->connect);

        my $val2 = await_f($redis2->get('auth:test:db1'));
        is($val2, undef, 'key not in db 0');

        $redis2->disconnect;
    };

    subtest 'CLIENT SETNAME works' => sub {
        my $redis = Future::IO::Redis->new(
            host        => $ENV{REDIS_HOST} // 'localhost',
            client_name => 'test-client-12345',
        );

        await_f($redis->connect);

        # Verify client name was set
        my $name = await_f($redis->command('CLIENT', 'GETNAME'));
        is($name, 'test-client-12345', 'client name set');

        $redis->disconnect;
    };

    subtest 'auth replayed on reconnect' => sub {
        my $connect_count = 0;

        my $redis = Future::IO::Redis->new(
            host        => $ENV{REDIS_HOST} // 'localhost',
            database    => 2,
            client_name => 'reconnect-test',
            reconnect   => 1,
            on_connect  => sub { $connect_count++ },
        );

        await_f($redis->connect);
        is($connect_count, 1, 'connected once');

        # Set key in db 2
        await_f($redis->set('auth:reconnect:key', 'val'));

        # Force disconnect
        close $redis->{socket};
        $redis->{connected} = 0;

        # Command should reconnect and still be in db 2
        my $val = await_f($redis->get('auth:reconnect:key'));
        is($val, 'val', 'still in database 2 after reconnect');
        is($connect_count, 2, 'reconnected');

        # Verify client name restored
        my $name = await_f($redis->command('CLIENT', 'GETNAME'));
        is($name, 'reconnect-test', 'client name restored');

        await_f($redis->del('auth:reconnect:key'));
        $redis->disconnect;
    };
}

# Password auth tests require Redis configured with requirepass
SKIP: {
    skip "Set REDIS_AUTH_HOST and REDIS_AUTH_PASS to test auth", 2
        unless $ENV{REDIS_AUTH_HOST} && $ENV{REDIS_AUTH_PASS};

    subtest 'password authentication works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_AUTH_HOST},
            password => $ENV{REDIS_AUTH_PASS},
        );

        await_f($redis->connect);
        my $pong = await_f($redis->ping);
        is($pong, 'PONG', 'authenticated successfully');

        $redis->disconnect;
    };

    subtest 'wrong password fails' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_AUTH_HOST},
            password => 'wrongpassword',
        );

        my $error;
        my $f = $redis->connect;
        $loop->await($f);
        eval { $f->get };
        $error = $@;

        ok($error, 'connection failed');
        like("$error", qr/auth|password|denied/i, 'error mentions auth');
    };
}

# ACL auth tests require Redis 6+ with ACL configured
SKIP: {
    skip "Set REDIS_ACL_HOST, REDIS_ACL_USER, REDIS_ACL_PASS to test ACL", 1
        unless $ENV{REDIS_ACL_HOST} && $ENV{REDIS_ACL_USER} && $ENV{REDIS_ACL_PASS};

    subtest 'ACL authentication works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_ACL_HOST},
            username => $ENV{REDIS_ACL_USER},
            password => $ENV{REDIS_ACL_PASS},
        );

        await_f($redis->connect);
        my $pong = await_f($redis->ping);
        is($pong, 'PONG', 'ACL authenticated successfully');

        $redis->disconnect;
    };
}

done_testing;
