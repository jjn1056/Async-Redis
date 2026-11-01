use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis ();   # selects the suite's Future::IO event loop
use Scalar::Util qw(refaddr weaken);
use Future::AsyncAwait;
use Async::Redis;
use Async::Redis::Error::Connection;

plan skip_all => 'REDIS_HOST not set' unless $ENV{REDIS_HOST};

sub new_redis { Async::Redis->new(host => $ENV{REDIS_HOST}, port => $ENV{REDIS_PORT} // 6379) }

subtest 'subscribe/unsubscribe_all/subscribe returns a fresh subscription object' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        my $sub1 = await $r->subscribe('ch-life-a');

        # Trigger _close by unsubscribing all channels. If no
        # unsubscribe_all method exists, use unsubscribe with the channel name.
        if ($sub1->can('unsubscribe_all')) {
            await $sub1->unsubscribe_all;
        } else {
            await $sub1->unsubscribe('ch-life-a');
        }

        my $sub2 = await $r->subscribe('ch-life-a');
        isnt refaddr($sub2), refaddr($sub1),
            'fresh subscription object after close';
        $sub2->_close;
        $r->disconnect;
    })->()->get;
};

subtest 'next() on a _close-d subscription returns undef' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        my $sub = await $r->subscribe('ch-close-test');
        $sub->_close;
        my $result = await $sub->next;
        is $result, undef, 'next returns undef after _close';
        $r->disconnect;
    })->()->get;
};

subtest 'next() on a _fail_fatal-ed subscription fails with typed error' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;
        my $sub = await $r->subscribe('ch-fatal-test');
        my $err = Async::Redis::Error::Connection->new(
            message => 'test fatal', host => 'x', port => 0,
        );
        $sub->_fail_fatal($err);
        my $ok = eval { await $sub->next; 1 };
        ok !$ok, 'next died';
        isa_ok $@, ['Async::Redis::Error::Connection'],
            'carries typed error';
        $r->disconnect;
    })->()->get;
};

subtest 'identity guard: stale _close does not clear a newer subscription' => sub {
    (async sub {
        my $r = new_redis();
        await $r->connect;

        my $sub1 = await $r->subscribe('ch-id-test');
        $sub1->_close;
        is $r->{_subscription}, undef, 'slot cleared by first close';

        my $sub2 = await $r->subscribe('ch-id-test');
        # Try to _close the stale $sub1 again. Must NOT clear $sub2's slot.
        $sub1->_close;
        is refaddr($r->{_subscription}), refaddr($sub2),
            'identity guard preserved newer subscription';
        $sub2->_close;
        $r->disconnect;
    })->()->get;
};

# A client and its subscription refer to each other; dropping the client
# must free both, and a subscription kept on its own must not hang.

subtest 'a client and its subscription are freed together' => sub {
    my ($weak_r, $weak_sub);
    {
        my $r = new_redis();
        $r->connect->get;
        my $sub = $r->subscribe('ch-life-free')->get;
        weaken($weak_r   = $r);
        weaken($weak_sub = $sub);
    }
    ok !defined $weak_r,   'the client is freed';
    ok !defined $weak_sub, 'the subscription is freed';
};

subtest 'a dropped subscribed client closes its connection' => sub {
    my $admin = new_redis();
    $admin->connect->get;
    my $id;
    {
        my $r = new_redis();
        $r->connect->get;
        $id = $r->client('ID')->get;
        my $sub = $r->subscribe('ch-life-closed')->get;
    }
    Future::IO->sleep(0.2)->get;
    my $list = $admin->client('LIST')->get;
    unlike $list, qr/^id=$id /m, 'the server no longer has it';
    $admin->disconnect;
};

subtest 'a subscription whose client is destroyed fails instead of hanging' => sub {
    my $r = new_redis();
    $r->connect->get;
    my $sub = $r->subscribe('ch-life-gone')->get;
    undef $r;
    my $next = $sub->next;
    my $timeout = Future::IO->sleep(2)->then(sub { Future->fail('timeout') });
    Future->wait_any($next->without_cancel, $timeout)->await;
    ok $next->is_failed, 'next fails';
    my ($e) = $next->is_failed ? $next->failure : ();
    isa_ok $e, 'Async::Redis::Error::Disconnected';
    like "$e", qr/Client destroyed/, 'saying why';
};

subtest 'callback mode: a destroyed client calls on_error once, no warning' => sub {
    my $r = new_redis();
    $r->connect->get;
    my $sub = $r->subscribe('ch-life-cb')->get;
    my @errors;
    $sub->on_message(sub {});
    $sub->on_error(sub { push @errors, $_[1] });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    undef $r;
    is scalar @errors, 1, 'on_error once';
    like $errors[0] // '', qr/Client destroyed/, 'with the reason';
    is \@warnings, [], 'no warnings';
};

done_testing;
