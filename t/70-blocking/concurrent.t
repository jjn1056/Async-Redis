# t/70-blocking/concurrent.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $redis1 = eval {
        my $r = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', connect_timeout => 2);
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis1;

    # Second connection for concurrent operations
    my $redis2 = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    await_f($redis2->connect);

    # Third connection for pushing data
    my $pusher = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
    await_f($pusher->connect);

    subtest 'multiple concurrent BLPOP on different queues' => sub {
        await_f($redis1->del('conc:q1', 'conc:q2'));

        # Start two BLPOP operations concurrently
        my $f1 = $redis1->blpop('conc:q1', 5);
        my $f2 = $redis2->blpop('conc:q2', 5);

        # Push to both after short delay
        await_f($loop->delay_future(after => 0.2));
        await_f($pusher->rpush('conc:q1', 'item1'));
        await_f($pusher->rpush('conc:q2', 'item2'));

        # Wait for both
        my @results = await_f(Future->needs_all($f1, $f2));

        is($results[0], ['conc:q1', 'item1'], 'first BLPOP got item');
        is($results[1], ['conc:q2', 'item2'], 'second BLPOP got item');

        # Cleanup
        await_f($redis1->del('conc:q1', 'conc:q2'));
    };

    subtest 'multiple BLPOP waiters on same queue' => sub {
        await_f($redis1->del('conc:shared'));

        # Two connections waiting on same queue
        my $f1 = $redis1->blpop('conc:shared', 5);
        my $f2 = $redis2->blpop('conc:shared', 5);

        # Small delay to ensure both are waiting
        await_f($loop->delay_future(after => 0.1));

        # Push two items so both waiters get something
        await_f($pusher->rpush('conc:shared', 'item1', 'item2'));

        # Wait for both
        my @results = await_f(Future->needs_all($f1, $f2));

        # Both should get something (order depends on which connected first)
        ok(defined $results[0], 'first waiter got an item');
        ok(defined $results[1], 'second waiter got an item');

        # Items should be different
        isnt($results[0][1], $results[1][1], 'waiters got different items');

        # Cleanup
        await_f($redis1->del('conc:shared'));
    };

    subtest 'non-blocking during concurrent waits' => sub {
        await_f($redis1->del('conc:nb'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Start concurrent BLPOP operations
        my $f1 = $redis1->blpop('conc:nb', 1);
        my $f2 = $redis2->blpop('conc:nb', 1);

        # Wait for both to timeout
        await_f(Future->needs_all($f1, $f2));

        $timer->stop;
        $loop->remove($timer);

        # Should tick throughout the concurrent waits
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times during concurrent BLPOPs");
    };
}

done_testing;
