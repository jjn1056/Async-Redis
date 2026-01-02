# t/80-scan/sscan.t
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
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

    # Setup test set
    await_f($redis->del('sscan:set'));
    for my $i (1..100) {
        await_f($redis->sadd('sscan:set', "member:$i"));
    }

    subtest 'sscan_iter iterates all members' => sub {
        my $iter = $redis->sscan_iter('sscan:set');

        my @all_members;
        while (my $batch = await_f($iter->next)) {
            push @all_members, @$batch;
        }

        is(scalar @all_members, 100, 'found all 100 members');

        my %unique = map { $_ => 1 } @all_members;
        is(scalar keys %unique, 100, 'all members unique');
    };

    subtest 'sscan_iter with match pattern' => sub {
        my $iter = $redis->sscan_iter('sscan:set', match => 'member:5*');

        my @all_members;
        while (my $batch = await_f($iter->next)) {
            push @all_members, @$batch;
        }

        # Should match member:5, member:50-59
        ok(scalar @all_members >= 10, 'matched member:5* pattern');
        ok((grep { $_ eq 'member:5' } @all_members), 'member:5 matched');
    };

    # Cleanup
    await_f($redis->del('sscan:set'));
}

done_testing;
