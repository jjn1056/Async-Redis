# t/50-pubsub/multiple-channels.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;
use Future::IO::Impl::IOAsync;
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

    subtest 'subscribe to many channels at once' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my @channels = map { "multi:chan:$_" } (1..10);

        my $sub = await_f($subscriber->subscribe(@channels));

        is($sub->channel_count, 10, 'subscribed to 10 channels');
        is([sort $sub->channels], [sort @channels], 'all channels tracked');

        $subscriber->disconnect;
    };

    subtest 'receive from multiple channels' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my @channels = map { "recv:chan:$_" } (1..5);
        my $sub = await_f($subscriber->subscribe(@channels));

        # Publish in background
        my $publish_future = (async sub {
            await Future::IO->sleep(0.1);
            for my $i (1..5) {
                await $publisher->publish("recv:chan:$i", "msg$i");
            }
        })->();

        my %received_by_channel;
        for my $i (1..5) {
            my $msg = await_f($sub->next);
            $received_by_channel{$msg->{channel}} = $msg->{data};
        }

        await_f($publish_future);

        is(scalar keys %received_by_channel, 5, 'received from 5 different channels');
        for my $i (1..5) {
            is($received_by_channel{"recv:chan:$i"}, "msg$i", "got message from chan $i");
        }

        $subscriber->disconnect;
    };

    subtest 'add channels to existing subscription' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        # Initial subscription
        my $sub = await_f($subscriber->subscribe('add:initial'));
        is($sub->channel_count, 1, 'initial subscription');

        # Add more channels
        await_f($subscriber->subscribe('add:second', 'add:third'));
        is($sub->channel_count, 3, 'added channels');
        is([sort $sub->channels], ['add:initial', 'add:second', 'add:third'], 'all tracked');

        $subscriber->disconnect;
    };

    $publisher->disconnect;
}

done_testing;
