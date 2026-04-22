use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future::IO;
use Async::Redis;

plan skip_all => 'REDIS_HOST not set' unless $ENV{REDIS_HOST};

sub new_redis {
    Async::Redis->new(
        host => $ENV{REDIS_HOST},
        port => $ENV{REDIS_PORT} // 6379,
    );
}

subtest 'single normal command round-trips' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        my $pong = await $r->command('PING');
        is $pong, 'PONG';
        $r->disconnect;
    })->()->get;
};

subtest 'two concurrent normal commands both succeed and match responses' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        await $r->set('k1', 'v1');
        await $r->set('k2', 'v2');

        my $f1 = $r->get('k1');
        my $f2 = $r->get('k2');
        my ($v1, $v2) = await Future->needs_all($f1, $f2);

        is $v1, 'v1', 'first command got its response';
        is $v2, 'v2', 'second command got its response';

        await $r->del('k1', 'k2');
        $r->disconnect;
    })->()->get;
};

subtest 'reader exits cleanly when inflight drains, restarts on next submission' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        await $r->set('k', '1');
        await $r->get('k');
        # If the reader doesn't exit, the next command's ensure_reader
        # would no-op and the command would hang. A second command
        # after a quiet period proves the reader restarts cleanly.
        await Future::IO->sleep(0.05);
        my $v = await $r->get('k');
        is $v, '1';
        await $r->del('k');
        $r->disconnect;
    })->()->get;
};

done_testing;
