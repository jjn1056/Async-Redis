# t/60-scripting/auto-fallback.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
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

    my $script = 'return KEYS[1] .. ":" .. ARGV[1]';
    my $sha = lc(sha1_hex($script));

    subtest 'evalsha_or_eval with unknown SHA falls back' => sub {
        # Flush scripts to ensure SHA unknown
        await_f($redis->script_flush);

        # This should try EVALSHA, get NOSCRIPT, then use EVAL
        my $result = await_f($redis->evalsha_or_eval(
            $sha,
            $script,
            1,
            'mykey',
            'myarg',
        ));

        is($result, 'mykey:myarg', 'fallback to EVAL worked');
    };

    subtest 'evalsha_or_eval with known SHA uses SHA' => sub {
        # Load the script
        await_f($redis->script_load($script));

        my $result = await_f($redis->evalsha_or_eval(
            $sha,
            $script,
            1,
            'key2',
            'arg2',
        ));

        is($result, 'key2:arg2', 'EVALSHA worked');
    };

    subtest 'evalsha_or_eval caches SHA after fallback' => sub {
        await_f($redis->script_flush);

        my $new_script = 'return "cached"';
        my $new_sha = lc(sha1_hex($new_script));

        # First call: fallback to EVAL
        my $r1 = await_f($redis->evalsha_or_eval($new_sha, $new_script, 0));
        is($r1, 'cached', 'first call worked');

        # Script should now be loaded on server
        my $exists = await_f($redis->script_exists($new_sha));
        is($exists->[0], 1, 'script now cached on server');

        # Second call should use EVALSHA directly
        my $r2 = await_f($redis->evalsha_or_eval($new_sha, $new_script, 0));
        is($r2, 'cached', 'second call worked');
    };
}

done_testing;
