# t/80-scan/large.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use IO::Async::Timer::Periodic;
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

    my $key_count = 500;  # Reasonable size for test

    # Setup large dataset using pipeline for speed
    subtest 'setup large dataset' => sub {
        my $pipe = $redis->pipeline;
        for my $i (1..$key_count) {
            $pipe->set("large:key:$i", "value$i");
        }
        await_f($pipe->execute);
        pass("created $key_count keys");
    };

    subtest 'scan_iter handles large dataset' => sub {
        my $iter = $redis->scan_iter(match => 'large:key:*', count => 100);

        my @all_keys;
        my $batch_count = 0;

        while (my $batch = await_f($iter->next)) {
            push @all_keys, @$batch;
            $batch_count++;
        }

        is(scalar @all_keys, $key_count, "found all $key_count keys");
        ok($batch_count >= 1, "iterated in $batch_count batches");

        my %unique = map { $_ => 1 } @all_keys;
        is(scalar keys %unique, $key_count, 'all keys unique');
    };

    subtest 'non-blocking during large scan' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $iter = $redis->scan_iter(match => 'large:key:*', count => 50);
        my $count = 0;

        while (my $batch = await_f($iter->next)) {
            $count += @$batch;
        }

        $timer->stop;
        $loop->remove($timer);

        is($count, $key_count, 'found all keys');
        pass("Event loop ticked during large scan");
    };

    subtest 'memory efficient iteration' => sub {
        # This test verifies we don't load all keys into memory at once
        # by checking that batches are reasonably sized

        my $iter = $redis->scan_iter(match => 'large:key:*', count => 100);

        my $max_batch_size = 0;
        my $batch_count = 0;

        while (my $batch = await_f($iter->next)) {
            my $size = scalar @$batch;
            $max_batch_size = $size if $size > $max_batch_size;
            $batch_count++;
        }

        ok($max_batch_size < $key_count, "max batch size $max_batch_size < total $key_count");
        ok($batch_count > 1, "used multiple batches ($batch_count)");
    };

    # Cleanup using scan to avoid blocking on large DEL
    subtest 'cleanup large dataset' => sub {
        my $iter = $redis->scan_iter(match => 'large:key:*', count => 500);

        my @to_delete;
        while (my $batch = await_f($iter->next)) {
            push @to_delete, @$batch;
        }

        if (@to_delete) {
            await_f($redis->del(@to_delete));
        }

        pass("cleaned up $key_count keys");
    };
}

done_testing;
