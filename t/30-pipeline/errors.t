# t/30-pipeline/errors.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use Future::IO::Redis;

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

    subtest 'command-level Redis error captured inline' => sub {
        await_f($redis->set('errors:string', 'hello'));

        my $results = await_f(
            $redis->pipeline
                ->set('errors:a', 1)
                ->lpush('errors:string', 'item')  # WRONGTYPE error
                ->set('errors:b', 2)
                ->execute
        );

        is($results->[0], 'OK', 'first SET succeeded');

        # Second command should contain WRONGTYPE error
        ok("$results->[1]" =~ /WRONGTYPE/i,
           'WRONGTYPE error captured');

        is($results->[2], 'OK', 'third SET succeeded (pipeline continued)');

        # Cleanup
        await_f($redis->del('errors:string', 'errors:a', 'errors:b'));
    };

    subtest 'multiple errors in single pipeline' => sub {
        await_f($redis->set('errors:s1', 'string1'));
        await_f($redis->set('errors:s2', 'string2'));

        my $results = await_f(
            $redis->pipeline
                ->lpush('errors:s1', 'item')  # WRONGTYPE error
                ->get('errors:s1')            # OK
                ->lpush('errors:s2', 'item')  # WRONGTYPE error
                ->get('errors:s2')            # OK
                ->execute
        );

        # Check errors captured at correct slots
        ok("$results->[0]" =~ /WRONGTYPE|ERR/i, 'slot 0 has error');
        is($results->[1], 'string1', 'slot 1 has value');
        ok("$results->[2]" =~ /WRONGTYPE|ERR/i, 'slot 2 has error');
        is($results->[3], 'string2', 'slot 3 has value');

        # Cleanup
        await_f($redis->del('errors:s1', 'errors:s2'));
    };

    subtest 'check each result for errors pattern' => sub {
        await_f($redis->set('errors:check', 'value'));

        my $results = await_f(
            $redis->pipeline
                ->get('errors:check')
                ->lpush('errors:check', 'item')  # Wrong type
                ->get('errors:nonexistent')
                ->execute
        );

        my @errors;
        for my $i (0 .. $#$results) {
            my $r = $results->[$i];
            if (ref $r || (defined $r && "$r" =~ /ERR|WRONGTYPE/i)) {
                push @errors, { index => $i, error => $r };
            }
        }

        is(scalar @errors, 1, 'found 1 error');
        is($errors[0]{index}, 1, 'error at index 1');

        # Cleanup
        await_f($redis->del('errors:check'));
    };

    subtest 'NOSCRIPT error captured' => sub {
        my $fake_sha = 'a' x 40;

        my $results = await_f(
            $redis->pipeline
                ->set('errors:x', 1)
                ->command('EVALSHA', $fake_sha, 0)
                ->get('errors:x')
                ->execute
        );

        is($results->[0], 'OK', 'SET succeeded');
        ok("$results->[1]" =~ /NOSCRIPT/i || ref $results->[1], 'NOSCRIPT captured');
        is($results->[2], '1', 'GET succeeded');

        # Cleanup
        await_f($redis->del('errors:x'));
    };
}

done_testing;
