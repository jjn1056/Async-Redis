# t/91-reliability/queue-overflow.t
use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use Test::Future::IO::Redis qw(init_loop skip_without_redis await_f cleanup_keys);

my $loop = init_loop();

SKIP: {
    my $redis = skip_without_redis();

    subtest 'pipeline handles many commands' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # Use pipeline for many commands
        my $pipe = $r->pipeline;
        for my $i (1..100) {
            $pipe->set("queue:key:$i", "value:$i");
        }

        # Execute pipeline
        my $results = await_f($pipe->execute);
        is(scalar @$results, 100, 'all SET commands completed');

        # Verify all returned OK
        my @oks = grep { $_ eq 'OK' } @$results;
        is(scalar @oks, 100, 'all SETs returned OK');

        # Verify values (sequential GETs)
        for my $i (1..10) {  # Just check first 10 for speed
            my $val = await_f($r->get("queue:key:$i"));
            is($val, "value:$i", "key $i has correct value");
        }

        cleanup_keys($r, 'queue:*');
        $r->disconnect;
    };

    subtest 'pipeline handles batch operations' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        my $pipe = $r->pipeline;

        # Queue many operations
        for my $i (1..50) {
            $pipe->set("pipe:key:$i", "value:$i");
        }

        # Execute pipeline
        my $results = await_f($pipe->execute);
        is(scalar @$results, 50, 'got 50 results');

        # Verify all are OK
        my @oks = grep { $_ eq 'OK' } @$results;
        is(scalar @oks, 50, 'all 50 returned OK');

        cleanup_keys($r, 'pipe:*');
        $r->disconnect;
    };

    subtest 'inflight tracking' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # Initially no inflight
        is($r->inflight_count, 0, 'no inflight initially');

        # Start some commands but don't await
        my @futures;
        for my $i (1..5) {
            push @futures, $r->set("inflight:key:$i", "val:$i");
        }

        # Wait for all to complete
        await_f(Future->wait_all(@futures));

        # After completion, inflight should be 0
        is($r->inflight_count, 0, 'no inflight after completion');

        cleanup_keys($r, 'inflight:*');
        $r->disconnect;
    };

    $redis->disconnect;
}

done_testing;
