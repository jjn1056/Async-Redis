# t/50-pubsub/psubscribe.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO;
Future::IO->load_impl("IOAsync");
use Future::AsyncAwait;
use Future::IO::Redis;
use Future;

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $publisher = eval {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    subtest 'psubscribe receives messages matching pattern' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my $sub = await_f($subscriber->psubscribe('news:*'));
        ok($sub->isa('Future::IO::Redis::Subscription'), 'returns Subscription');
        is([sort $sub->patterns], ['news:*'], 'tracks subscribed patterns');

        # Publish in background
        my $publish_future = (async sub {
            await Future::IO->sleep(0.1);
            await $publisher->publish('news:sports', 'Game update');
            await $publisher->publish('news:weather', 'Sunny skies');
            await $publisher->publish('news:tech', 'New release');
        })->();

        # Receive 3 messages
        my @received;
        for my $i (1..3) {
            my $msg = await_f($sub->next);
            push @received, $msg;
        }

        await_f($publish_future);

        is(scalar @received, 3, 'received 3 messages');
        is($received[0]{type}, 'pmessage', 'pmessage type');
        is($received[0]{pattern}, 'news:*', 'pattern field populated');
        ok($received[0]{channel} =~ /^news:/, 'actual channel matches');
        ok(defined $received[0]{data}, 'has data');

        $subscriber->disconnect;
    };

    subtest 'psubscribe with multiple patterns' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my $sub = await_f($subscriber->psubscribe('alert:*', 'log:*'));
        is([sort $sub->patterns], ['alert:*', 'log:*'], 'both patterns tracked');

        # Publish in background
        my $publish_future = (async sub {
            await Future::IO->sleep(0.1);
            await $publisher->publish('alert:critical', 'System down');
            await $publisher->publish('log:info', 'User logged in');
        })->();

        my @received;
        for my $i (1..2) {
            my $msg = await_f($sub->next);
            push @received, $msg;
        }

        await_f($publish_future);

        is(scalar @received, 2, 'received from both patterns');

        my %by_pattern = map { $_->{pattern} => $_->{data} } @received;
        is($by_pattern{'alert:*'}, 'System down', 'got alert message');
        is($by_pattern{'log:*'}, 'User logged in', 'got log message');

        $subscriber->disconnect;
    };

    $publisher->disconnect;
}

done_testing;
