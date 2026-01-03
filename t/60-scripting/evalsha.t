# t/60-scripting/evalsha.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use Future::IO::Redis;
use Digest::SHA qw(sha1_hex);

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $redis = eval {
        my $r = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', connect_timeout => 2);
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    my $script = 'return "hello from sha"';
    my $sha = lc(sha1_hex($script));

    subtest 'SCRIPT LOAD' => sub {
        my $result = await_f($redis->script_load($script));
        is($result, $sha, 'SCRIPT LOAD returns SHA');
    };

    subtest 'EVALSHA with loaded script' => sub {
        my $result = await_f($redis->evalsha($sha, 0));
        is($result, 'hello from sha', 'EVALSHA executed');
    };

    subtest 'EVALSHA with unknown SHA fails' => sub {
        my $fake_sha = 'a' x 40;

        my $error;
        eval {
            await_f($redis->evalsha($fake_sha, 0));
        };
        $error = $@;

        ok($error, 'EVALSHA with unknown SHA threw');
        like("$error", qr/NOSCRIPT/i, 'NOSCRIPT error');
    };

    subtest 'SCRIPT EXISTS' => sub {
        my $fake_sha = 'b' x 40;

        my $result = await_f($redis->script_exists($sha, $fake_sha));
        is($result, [1, 0], 'EXISTS returns array of 0/1');
    };

    subtest 'SCRIPT FLUSH' => sub {
        # Load a script
        my $temp_script = 'return "temp"';
        my $temp_sha = await_f($redis->script_load($temp_script));

        # Verify it exists
        my $exists = await_f($redis->script_exists($temp_sha));
        is($exists->[0], 1, 'script exists before flush');

        # Flush
        await_f($redis->script_flush);

        # Verify it's gone
        $exists = await_f($redis->script_exists($temp_sha));
        is($exists->[0], 0, 'script gone after flush');
    };
}

done_testing;
