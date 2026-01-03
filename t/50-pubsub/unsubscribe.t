# t/50-pubsub/unsubscribe.t
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
    my $redis = eval {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'subscription tracks channels for replay' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my $sub = await_f($subscriber->subscribe('chan:a', 'chan:b'));
        await_f($subscriber->psubscribe('pattern:*'));

        my @replay = $sub->get_replay_commands;

        is(scalar @replay, 2, 'two replay commands');

        my ($sub_cmd) = grep { $_->[0] eq 'SUBSCRIBE' } @replay;
        my ($psub_cmd) = grep { $_->[0] eq 'PSUBSCRIBE' } @replay;

        ok($sub_cmd, 'has SUBSCRIBE command');
        ok($psub_cmd, 'has PSUBSCRIBE command');
        is([sort @{$sub_cmd}[1..$#$sub_cmd]], ['chan:a', 'chan:b'], 'SUBSCRIBE channels');
        is($psub_cmd, ['PSUBSCRIBE', 'pattern:*'], 'PSUBSCRIBE pattern');

        $subscriber->disconnect;
    };

    subtest 'channel count includes all types' => sub {
        my $subscriber = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($subscriber->connect);

        my $sub = await_f($subscriber->subscribe('regular:chan'));
        is($sub->channel_count, 1, 'one channel');

        await_f($subscriber->psubscribe('pat:*'));
        is($sub->channel_count, 2, 'two after pattern added');

        $subscriber->disconnect;
    };

    $redis->disconnect;
}

done_testing;
