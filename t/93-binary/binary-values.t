# t/93-binary/binary-values.t
use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use Test::Future::IO::Redis qw(init_loop skip_without_redis await_f cleanup_keys);

my $loop = init_loop();

SKIP: {
    my $redis = skip_without_redis();

    subtest 'binary data with null bytes' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        my $binary = "hello\x00world\x00binary";
        await_f($r->set('bin:null', $binary));

        my $result = await_f($r->get('bin:null'));
        is($result, $binary, 'null bytes preserved');
        is(length($result), length($binary), 'length preserved');

        cleanup_keys($r, 'bin:*');
        $r->disconnect;
    };

    subtest 'binary data with high bytes' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        my $binary = join('', map { chr($_) } 0..255);
        await_f($r->set('bin:high', $binary));

        my $result = await_f($r->get('bin:high'));
        is(length($result), 256, 'all 256 bytes preserved');
        is($result, $binary, 'byte values preserved');

        cleanup_keys($r, 'bin:*');
        $r->disconnect;
    };

    subtest 'binary keys' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        my $key = "key\x00with\x00nulls";
        await_f($r->set($key, 'value'));

        my $result = await_f($r->get($key));
        is($result, 'value', 'binary key works');

        await_f($r->del($key));
        $r->disconnect;
    };

    subtest 'CRLF in values' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        my $value = "line1\r\nline2\r\nline3";
        await_f($r->set('bin:crlf', $value));

        my $result = await_f($r->get('bin:crlf'));
        is($result, $value, 'CRLF preserved');

        cleanup_keys($r, 'bin:*');
        $r->disconnect;
    };

    subtest 'large binary values' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # 1MB of random binary data
        my $size = 1024 * 1024;
        my $binary = '';
        for (1..$size) {
            $binary .= chr(int(rand(256)));
        }

        await_f($r->set('bin:large', $binary));

        my $result = await_f($r->get('bin:large'));
        is(length($result), $size, 'large binary preserved');

        cleanup_keys($r, 'bin:*');
        $r->disconnect;
    };

    $redis->disconnect;
}

done_testing;
