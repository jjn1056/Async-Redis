# t/95-connection-lifetime/reader-failure-containment.t
#
# When the reader fails, its failure is delivered to the requests waiting on
# that connection. An exception raised while doing that (a user callback that
# dies, or a callback-mode subscription with no on_error) has no caller left
# to receive it. It must be reported as a warning, never thrown into the
# event loop, which would break the loop for every connection sharing it,
# and never silently lost.

use strict;
use warnings;
use Test2::V0;
use Test::Lib;
use Test::Async::Redis qw(run settle failure_of inject_reader_bug inject_eof
                          skip_without_redis cleanup_keys);
use Future::IO;
use Async::Redis;

$SIG{PIPE} = 'IGNORE';

sub loop_still_works {
    return lives { run { Future::IO->sleep(0.05) } };
}

SKIP: {
    my $redis = skip_without_redis();

    subtest 'a callback dying during a reader crash does not break the event loop' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $r = Async::Redis->new(
            host          => $ENV{REDIS_HOST} // 'localhost',
            on_disconnect => sub { die "CALLBACK_DIED\n" },
        );
        run { $r->connect };

        my $guard = inject_reader_bug($r);
        my $ping  = $r->command('PING');
        is settle($ping), 'failed', 'the waiting command fails';
        isa_ok failure_of($ping), 'Async::Redis::Error::Connection';
        undef $guard;

        ok loop_still_works(), 'the event loop still runs afterwards';
        ok((grep { /CALLBACK_DIED/ } @warnings), 'the callback\'s death is reported')
            or diag "warnings: @warnings";
        eval { $r->disconnect };
    };

    subtest 'a listener with no on_error is reported, not thrown into the event loop' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $admin = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $admin->connect };
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', reconnect => 0);
        run { $r->connect };
        my $sub = run { $r->subscribe('lt:contain') };
        my @messages;
        $sub->on_message(sub { push @messages, $_[1] });

        my $guard = inject_reader_bug($r);
        my $pub   = $admin->publish('lt:contain', 'hello');
        settle($pub);
        my $closed = eval {
            run { Future::IO->sleep(0.01) } for 1 .. 100;
            $sub->is_closed;
        };
        undef $guard;

        ok $sub->is_closed, 'the subscription is closed';
        ok loop_still_works(), 'the event loop still runs afterwards';
        ok((grep { /Reader failed: INJECTED_READER_BUG/ } @warnings),
            'the listener\'s fatal error is reported')
            or diag "warnings: @warnings";
        eval { $r->disconnect };
        eval { $admin->disconnect };
    };

    subtest 'a callback dying during a handled read failure is reported' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $r = Async::Redis->new(
            host          => $ENV{REDIS_HOST} // 'localhost',
            on_disconnect => sub { die "CALLBACK_DIED\n" },
        );
        run { $r->connect };
        run { $r->del('lt:missing') };

        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        run { Future::IO->sleep(0.05) };
        inject_eof($r);                       # an ordinary, handled EOF
        is settle($blpop), 'failed', 'the waiting command fails';

        ok loop_still_works(), 'the event loop still runs afterwards';
        ok((grep { /CALLBACK_DIED/ } @warnings), 'the callback\'s death is reported')
            or diag "warnings: @warnings";

        run { $r->connect };
        my $ping = $r->command('PING');
        is settle($ping), 'done', 'the next connection is unaffected';
        eval { $r->disconnect };
    };

    subtest 'on_disconnect calling disconnect' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $fired = 0;
        my $r = Async::Redis->new(
            host          => $ENV{REDIS_HOST} // 'localhost',
            on_disconnect => sub { $fired++; $_[0]->disconnect },
        );
        run { $r->connect };
        run { $r->del('lt:missing') };

        my $blpop = $r->command('BLPOP', 'lt:missing', '1');
        run { Future::IO->sleep(0.05) };
        inject_eof($r);
        is settle($blpop), 'failed', 'the waiting command fails';

        is $fired, 1, 'on_disconnect fires once';
        is \@warnings, [], 'no warnings';
        ok !$r->is_connected, 'the client ends disconnected';
    };

    # A reconnect fails a loop turn after the drop, outside the reader. The
    # subscription's fatal error is raised from the reconnect task then.
    subtest 'a listener with no on_error is reported when reconnect gives up' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $admin = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $admin->connect };
        my $r = Async::Redis->new(
            host                   => $ENV{REDIS_HOST} // 'localhost',
            reconnect              => 1,
            reconnect_max_attempts => 1,
            reconnect_delay        => 0,
            reconnect_delay_max    => 0,
            reconnect_jitter       => 0,
        );
        run { $r->connect };
        my $id  = run { $r->client('ID') };
        my $sub = run { $r->subscribe('lt:contain:rc') };
        $sub->on_message(sub { });

        {
            no warnings 'redefine';
            local *Async::Redis::connect = sub {
                Future::IO->sleep(0.02)->then(sub {
                    Future->fail(Async::Redis::Error::Disconnected->new(
                        message => 'connect failed'));
                });
            };
            run { $admin->client('KILL', 'ID', $id) };
            my $thrown = dies { run { Future::IO->sleep(0.01) } for 1 .. 100 };
            is $thrown, undef, 'nothing is thrown into the event loop';
        }

        ok $sub->is_closed, 'the subscription is closed';
        ok loop_still_works(), 'the event loop still runs afterwards';
        ok((grep { /no on_error.*Reconnect gave up after 1 attempts/s } @warnings),
            'the exhausted reconnect is reported')
            or diag "warnings: @warnings";
        eval { $admin->disconnect };
    };

    # Completing a reply runs the caller's continuation synchronously, inside
    # the reader's drain loop. A caller that disconnects there tears the
    # connection down while a second reply is still in the read buffer.
    subtest 'a caller disconnecting from inside its reply does not crash the reader' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $r = Async::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        run { $r->connect };

        my $first  = $r->command('PING');
        my $second = $r->command('PING');     # its reply arrives in the same read
        my $done   = $first->then(sub { $r->disconnect; Future->done });
        settle($_) for $done, $second;

        is settle($first), 'done', 'the first command completes';
        is settle($second), 'failed', 'the second command fails';
        isa_ok failure_of($second), 'Async::Redis::Error::Disconnected';
        ok loop_still_works(), 'the event loop still runs afterwards';
        is \@warnings, [], 'the reader stops cleanly, with no warnings';
    };

    cleanup_keys($redis, 'lt:*');
}

done_testing;
