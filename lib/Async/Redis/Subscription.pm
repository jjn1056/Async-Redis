package Async::Redis::Subscription;

use strict;
use warnings;
use 5.018;

use Carp ();
use Future;
use Future::AsyncAwait;
use Future::IO;
use Scalar::Util qw(blessed refaddr weaken);

our $VERSION = '0.001';

# Synchronous recursion depth for the callback driver loop. See
# _start_driver. Package-level so local() can scope it dynamically —
# local() cannot be applied to lexicals.
our $SYNC_DEPTH = 0;
use constant MAX_SYNC_DEPTH => 32;

sub new {
    my ($class, %args) = @_;

    return bless {
        redis             => $args{redis},
        channels          => {},      # channel => 1 (for regular subscribe)
        patterns          => {},      # pattern => 1 (for psubscribe)
        sharded_channels  => {},      # channel => 1 (for ssubscribe)
        _pending_messages => [],      # Queued messages for iterator consumers
        _message_waiter   => undef,   # Future signalled when a message arrives
        _slot_waiter      => undef,   # Future signalled when queue drains below depth
        _fatal_error      => undef,   # Typed error set by _fail_fatal
        _on_reconnect     => undef,   # Callback for reconnect notification
        _on_message       => undef,   # Message-arrived callback (callback mode)
        _on_error         => undef,   # Fatal-error callback
        _driver_step      => undef,   # Running driver loop closure
        _current_read     => undef,   # Strong ref to in-flight read Future (F::AA GC pin)
        _closed           => 0,
    }, $class;
}

# Set/get reconnect callback
sub on_reconnect {
    my ($self, $cb) = @_;
    $self->{_on_reconnect} = $cb if @_ > 1;
    return $self->{_on_reconnect};
}

# Set/get message-arrived callback. Once set, next() croaks — the
# subscription is in callback mode for the rest of its lifetime.
# $cb->($sub, $msg) receives the Subscription and the message hashref.
sub on_message {
    my ($self, $cb) = @_;
    if (@_ > 1) {
        if (!$cb && $self->{_on_message}) {
            Carp::croak(
                "on_message is sticky; cannot clear once set "
              . "(construct a new Subscription for iterator mode)"
            );
        }
        $self->{_on_message} = $cb;
        # If the subscription already has channels and is open, start
        # the driver. If not, it'll be started when channels are added.
        $self->_start_driver if $cb;
    }
    return $self->{_on_message};
}

# Set/get fatal-error callback. Fires once per fatal error; default
# (when unset) is to die so silent death is impossible.
# $cb->($sub, $err) receives the Subscription and the error.
sub on_error {
    my ($self, $cb) = @_;
    if (@_ > 1) {
        $self->{_on_error} = $cb;
    }
    return $self->{_on_error};
}

# Invoke a user-supplied callback with the standard exception-handling
# policy: save/restore $@, use eval-and-check-boolean idiom to survive
# DESTROY side effects, and route die to the fatal-error handler.
# Returns the callback's return value. Task 7 wires backpressure: if
# the return is a Future the driver will await it before the next
# read. Task 6's driver does not yet consume the return value.
sub _invoke_user_callback {
    my ($self, $cb, $msg) = @_;
    local $@;
    my $result;
    my $ok = eval {
        $result = $cb->($self, $msg);
        1;
    };
    unless ($ok) {
        my $err = $@ // 'unknown error';
        $self->_handle_fatal_error("on_message callback died: $err");
        return undef;
    }
    return $result;
}

# Single chokepoint for fatal errors from either the read loop or the
# callback path. Closes the subscription, fires on_error if registered,
# and dies loudly if not. Loud-by-default prevents silent zombies.
sub _handle_fatal_error {
    my ($self, $err) = @_;
    $self->_close;
    if (my $cb = $self->{_on_error}) {
        local $@;
        my $ok = eval { $cb->($self, $err); 1 };
        unless ($ok) {
            Carp::carp("on_error callback died: " . ($@ // 'unknown error'));
        }
        return;
    }
    die $err;
}

# Track a channel subscription
sub _add_channel {
    my ($self, $channel) = @_;
    $self->{channels}{$channel} = 1;
    $self->_start_driver;
}

sub _add_pattern {
    my ($self, $pattern) = @_;
    $self->{patterns}{$pattern} = 1;
    $self->_start_driver;
}

sub _add_sharded_channel {
    my ($self, $channel) = @_;
    $self->{sharded_channels}{$channel} = 1;
    $self->_start_driver;
}

sub _remove_channel {
    my ($self, $channel) = @_;
    delete $self->{channels}{$channel};
}

sub _remove_pattern {
    my ($self, $pattern) = @_;
    delete $self->{patterns}{$pattern};
}

sub _remove_sharded_channel {
    my ($self, $channel) = @_;
    delete $self->{sharded_channels}{$channel};
}

# List subscribed channels/patterns
sub channels { keys %{shift->{channels}} }
sub patterns { keys %{shift->{patterns}} }
sub sharded_channels { keys %{shift->{sharded_channels}} }

sub channel_count {
    my ($self) = @_;
    return scalar(keys %{$self->{channels}})
         + scalar(keys %{$self->{patterns}})
         + scalar(keys %{$self->{sharded_channels}});
}

# Receive next message (async iterator pattern). Reads from the shared
# _pending_messages queue populated by the read driver. Waits on
# _message_waiter when the queue is empty. Returns undef on clean close;
# dies with the typed error on fatal close.
async sub next {
    my ($self) = @_;

    # Exclusivity check: callback mode disables iterator mode.
    if ($self->{_on_message}) {
        Carp::croak("Cannot call next() on a callback-driven subscription");
    }

    # Ensure the driver is running to fill the queue. Pass force=1 to
    # bypass the _on_message gate (iterator mode has no callback, but
    # still needs the driver). We call this after subscribe() has finished
    # reading all confirmation frames, so there's no race.
    $self->_start_driver(1);

    while (!@{$self->{_pending_messages}}) {
        die $self->{_fatal_error} if $self->{_fatal_error};
        return undef              if $self->{_closed};
        $self->{_message_waiter} //= Future->new;
        await $self->{_message_waiter};
        delete $self->{_message_waiter};
    }

    die $self->{_fatal_error} if $self->{_fatal_error};
    return undef              if $self->{_closed} && !@{$self->{_pending_messages}};

    my $msg = shift @{$self->{_pending_messages}};
    if (my $w = delete $self->{_slot_waiter}) {
        $w->done unless $w->is_ready;
    }
    return $msg;
}

# Read one pub/sub frame from the underlying connection. On transient
# read error, attempt reconnect if enabled and fire on_reconnect on
# success; on unrecoverable failure, propagate the error.
# Returns a Future resolving to the raw frame (arrayref) or undef if
# the connection is gone and no more frames are available.
# Shared by next() and the callback driver loop added in a later task.
async sub _read_frame_with_reconnect {
    my ($self) = @_;
    my $redis = $self->{redis};

    while (1) {
        my $frame;
        my $ok = eval {
            $frame = await $redis->_read_pubsub_frame;
            1;
        };

        unless ($ok) {
            my $error = $@;
            if ($redis->{reconnect} && $self->channel_count > 0) {
                my $reconnect_error;
                my $reconnect_ok = eval {
                    await $redis->_reconnect_pubsub;
                    1;
                };
                $reconnect_error = $@ unless $reconnect_ok;
                unless ($reconnect_ok) {
                    die $reconnect_error;
                }

                if ($self->{_on_reconnect}) {
                    $self->{_on_reconnect}->($self);
                }

                next;
            }
            die $error;
        }

        return $frame;
    }
}

# Convert a raw RESP pub/sub frame into a message hashref and deliver it.
# In callback mode, invokes _on_message via _invoke_user_callback and
# returns its result (which may be a Future for consumer-side backpressure).
# In iterator mode, queues the message into _pending_messages and signals
# _message_waiter so a blocked next() can wake up.
#
# Non-message frames (subscribe confirmations, etc.) return undef and
# take no action — the driver loop will read the next frame.
sub _dispatch_frame {
    my ($self, $frame) = @_;
    return unless $frame && ref $frame eq 'ARRAY';

    my $type = $frame->[0] // '';
    my $msg;

    if ($type eq 'message') {
        $msg = {
            type    => 'message',
            channel => $frame->[1],
            pattern => undef,
            data    => $frame->[2],
        };
    }
    elsif ($type eq 'pmessage') {
        $msg = {
            type    => 'pmessage',
            pattern => $frame->[1],
            channel => $frame->[2],
            data    => $frame->[3],
        };
    }
    elsif ($type eq 'smessage') {
        $msg = {
            type    => 'smessage',
            channel => $frame->[1],
            pattern => undef,
            data    => $frame->[2],
        };
    }
    else {
        return undef;   # non-message frame (subscribe confirmation, etc.)
    }

    if (my $cb = $self->{_on_message}) {
        return $self->_invoke_user_callback($cb, $msg);
    }

    # Iterator mode: queue respecting message_queue_depth. If the queue is
    # at capacity, return a Future that resolves once the consumer dequeues
    # (via next()). The caller (_run_reader or _start_driver) awaits it,
    # pausing socket reads and restoring TCP backpressure to the publisher.
    return if $self->{_closed};

    my $redis = $self->{redis};
    my $depth = ($redis && $redis->{message_queue_depth})
        ? $redis->{message_queue_depth}
        : 0;  # 0 = unbounded (default)

    if ($depth && scalar(@{$self->{_pending_messages}}) >= $depth) {
        # Queue full. Return a Future that queues the message once a slot
        # opens (signalled by next() calling _slot_waiter->done).
        $self->{_slot_waiter} //= Future->new;
        my $slot = $self->{_slot_waiter};
        weaken(my $weak = $self);
        return $slot->then(sub {
            return Future->done if !$weak || $weak->{_closed};
            push @{$weak->{_pending_messages}}, $msg;
            if (my $w = delete $weak->{_message_waiter}) {
                $w->done unless $w->is_ready;
            }
            Future->done;
        });
    }

    push @{$self->{_pending_messages}}, $msg;
    if (my $w = delete $self->{_message_waiter}) {
        $w->done unless $w->is_ready;
    }
    return undef;
}

# Start the read driver loop if not already running. Idempotent.
# In callback mode (_on_message set), auto-starts when channels are
# added via _add_channel/_add_pattern/_add_sharded_channel.
# In iterator mode, started explicitly by next() via _start_driver(1).
# Uses weak refs on $self and $step to break cycles so DESTROY fires
# promptly when external refs drop. Uses local($SYNC_DEPTH) to bound
# synchronous recursion depth when on_done fires synchronously (as
# it does when the underlying read buffer has multiple frames ready);
# past MAX_SYNC_DEPTH iterations, yields to the loop via Future::IO->later.
sub _start_driver {
    my ($self, $force) = @_;
    return if $self->{_driver_step};
    return unless $self->{_on_message} || $force;
    return if $self->{_closed};
    return unless $self->channel_count > 0;

    weaken(my $weak = $self);

    my $step;
    my $weak_step;
    $step = sub {
        return unless $weak && !$weak->{_closed};

        # Trampoline: once 32 synchronous iterations deep, yield to the
        # loop. Prevents stack overflow when a single TCP recv delivers
        # many buffered frames whose Futures are already ready.
        if ($SYNC_DEPTH >= MAX_SYNC_DEPTH) {
            # Yield to the event loop so we don't blow the call stack when
            # many buffered frames arrive synchronously. Future::IO->sleep(0)
            # is the correct way to schedule a deferred callback.
            Future::IO->sleep(0)->on_done(sub {
                $weak_step->() if $weak_step && $weak && !$weak->{_closed};
            });
            return;
        }
        local $SYNC_DEPTH = $SYNC_DEPTH + 1;

        # Keep a strong ref to the in-flight read Future on the
        # subscription so the async sub behind _read_frame_with_reconnect
        # isn't GC'd mid-suspension (F::AA's "lost returning future").
        my $f = $weak->{_current_read} = $weak->_read_frame_with_reconnect;

        $f->on_done(sub {
            return unless $weak && !$weak->{_closed};
            $weak->{_current_read} = undef;
            my $cb_result = $weak->_dispatch_frame($_[0]);
            if (blessed($cb_result) && $cb_result->isa('Future')) {
                # Consumer-opted backpressure: wait for their Future
                # before reading the next frame. Failures route to
                # on_error (same path as a raised callback exception).
                $cb_result->on_ready(sub {
                    return unless $weak && !$weak->{_closed};
                    my $res = shift;
                    if ($res->is_failed) {
                        $weak->_handle_fatal_error(
                            "on_message callback Future failed: " . $res->failure
                        );
                        return;
                    }
                    $weak_step->() if $weak_step && $weak && !$weak->{_closed};
                });
            } else {
                $weak_step->() if $weak_step && $weak && !$weak->{_closed};
            }
        });

        $f->on_fail(sub {
            return unless $weak;
            $weak->{_current_read} = undef;
            # If the user closed the subscription (or the underlying
            # client disconnected) while a read was in flight, a
            # "Connection closed by server" failure is expected, not
            # fatal. Short-circuit so we don't die through _handle_fatal_error.
            return if $weak->{_closed};
            $weak->_handle_fatal_error($_[0]);
        });
    };

    weaken($weak_step = $step);

    $self->{_driver_step} = $step;
    $step->();
    return;
}

# Backward-compatible wrapper
async sub next_message {
    my ($self) = @_;
    my $msg = await $self->next();
    return undef unless $msg;

    # Convert new format to old format for compatibility
    return {
        channel => $msg->{channel},
        message => $msg->{data},
        pattern => $msg->{pattern},
        type    => $msg->{type},
    };
}

# Intentional teardown: marks the subscription closed and wakes any
# blocked next() with undef. Clears the parent _subscription slot
# with an identity guard so a stale _close cannot evict a newer
# subscription object that reused the same slot.
sub _close {
    my ($self) = @_;
    return if $self->{_closed};
    $self->{_closed} = 1;

    $self->{_pending_messages} = [];

    if (my $w = delete $self->{_message_waiter}) {
        $w->done unless $w->is_ready;
    }
    if (my $w = delete $self->{_slot_waiter}) {
        $w->done unless $w->is_ready;
    }

    # Identity-guarded parent-slot clear.
    my $redis = $self->{redis};
    if ($redis && defined $redis->{_subscription}
        && refaddr($redis->{_subscription}) == refaddr($self)) {
        delete $redis->{_subscription};
    }

    # Release the driver closure; weak refs already broke the cycle.
    # Do NOT clear _current_read — the in-flight read Future must stay
    # pinned until it resolves, or F::AA will warn "lost its returning
    # future". on_done/on_fail will clear it and see _closed first.
    $self->{_driver_step} = undef;
}

# Unrecoverable failure: marks the subscription closed with a typed
# error. Any blocked next() will die with that error. The error is
# preserved for callers who call next() after the fact.
sub _fail_fatal {
    my ($self, $typed_error) = @_;
    return if $self->{_closed};
    $self->{_closed}      = 1;
    $self->{_fatal_error} = $typed_error;

    $self->{_pending_messages} = [];

    if (my $w = delete $self->{_message_waiter}) {
        $w->fail($typed_error) unless $w->is_ready;
    }
    if (my $w = delete $self->{_slot_waiter}) {
        $w->done unless $w->is_ready;
    }

    # Identity-guarded parent-slot clear.
    my $redis = $self->{redis};
    if ($redis && defined $redis->{_subscription}
        && refaddr($redis->{_subscription}) == refaddr($self)) {
        delete $redis->{_subscription};
    }

    $self->{_driver_step} = undef;
}

# Called before a reconnect attempt. Does NOT mark the subscription
# closed — the reader has already exited (connection dropped). Channels
# and patterns remain in their tracking hashes for replay via
# _resume_after_reconnect.
sub _pause_for_reconnect {
    my ($self) = @_;
    # Do NOT set _closed; do NOT fail waiters. Reader has already exited.
    # The driver will be restarted by _resume_after_reconnect.
    $self->{_driver_step} = undef;
    return;
}

# Replays all tracked subscriptions on a freshly reconnected socket.
# Sets in_pubsub=1 BEFORE sending SUBSCRIBE/PSUBSCRIBE/SSUBSCRIBE so
# racing message frames classify correctly (mirrors initial-subscribe timing).
async sub _resume_after_reconnect {
    my ($self) = @_;
    my $redis = $self->{redis} or return;
    $redis->{in_pubsub} = 1;

    my @channels = keys %{$self->{channels}};
    my @patterns = keys %{$self->{patterns}};
    my @sharded  = keys %{$self->{sharded_channels}};

    if (@channels) {
        await $redis->_send_command('SUBSCRIBE', @channels);
        for my $ch (@channels) { await $redis->_read_pubsub_frame }
    }
    if (@patterns) {
        await $redis->_send_command('PSUBSCRIBE', @patterns);
        for my $p (@patterns) { await $redis->_read_pubsub_frame }
    }
    if (@sharded) {
        await $redis->_send_command('SSUBSCRIBE', @sharded);
        for my $ch (@sharded) { await $redis->_read_pubsub_frame }
    }

    if (my $cb = $self->{_on_reconnect}) {
        $cb->($self);
    }

    # Restart the driver in whichever mode the subscription is in.
    $self->_start_driver($self->{_on_message} ? 0 : 1);
}

# Unsubscribe from specific channels
async sub unsubscribe {
    my ($self, @channels) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@channels) {
        # Partial unsubscribe
        await $redis->_send_command('UNSUBSCRIBE', @channels);

        # Read confirmations
        for my $ch (@channels) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_channel($ch);
        }
    }
    else {
        # Full unsubscribe - all channels
        my @all_channels = $self->channels;

        if (@all_channels) {
            await $redis->_send_command('UNSUBSCRIBE');

            # Read all confirmations
            for my $ch (@all_channels) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_channel($ch);
            }
        }
    }

    # If no subscriptions remain, close and exit pubsub mode
    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}

# Unsubscribe from patterns
async sub punsubscribe {
    my ($self, @patterns) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@patterns) {
        await $redis->_send_command('PUNSUBSCRIBE', @patterns);

        for my $p (@patterns) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_pattern($p);
        }
    }
    else {
        my @all_patterns = $self->patterns;

        if (@all_patterns) {
            await $redis->_send_command('PUNSUBSCRIBE');

            for my $p (@all_patterns) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_pattern($p);
            }
        }
    }

    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}

# Unsubscribe from sharded channels
async sub sunsubscribe {
    my ($self, @channels) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@channels) {
        await $redis->_send_command('SUNSUBSCRIBE', @channels);

        for my $ch (@channels) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_sharded_channel($ch);
        }
    }
    else {
        my @all = $self->sharded_channels;

        if (@all) {
            await $redis->_send_command('SUNSUBSCRIBE');

            for my $ch (@all) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_sharded_channel($ch);
            }
        }
    }

    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}


sub is_closed { shift->{_closed} }

# Get all subscriptions for reconnect replay
sub get_replay_commands {
    my ($self) = @_;

    my @commands;

    my @channels = $self->channels;
    push @commands, ['SUBSCRIBE', @channels] if @channels;

    my @patterns = $self->patterns;
    push @commands, ['PSUBSCRIBE', @patterns] if @patterns;

    my @sharded = $self->sharded_channels;
    push @commands, ['SSUBSCRIBE', @sharded] if @sharded;

    return @commands;
}

1;

__END__

=encoding utf8

=head1 NAME

Async::Redis::Subscription - PubSub subscription handler

=head1 SYNOPSIS

    my $sub = await $redis->subscribe('channel1', 'channel2');

    while (my $msg = await $sub->next) {
        say "Channel: $msg->{channel}";
        say "Data: $msg->{data}";
    }

    await $sub->unsubscribe('channel1');
    await $sub->unsubscribe;  # all remaining

=head1 DESCRIPTION

Manages Redis PubSub subscriptions with async iterator pattern.

=head1 MESSAGE STRUCTURE

    {
        type    => 'message',      # or 'pmessage', 'smessage'
        channel => 'channel_name',
        pattern => 'pattern',      # defined for pmessage, undef otherwise
        data    => 'payload',
    }

The C<pattern> key is always present. It is defined for C<pmessage>
frames (the matching glob pattern) and C<undef> for C<message> and
C<smessage> frames. Consumers do not need C<exists $msg-E<gt>{pattern}>
checks.

C<next()> always returns real pub/sub messages. Reconnection is transparent.

=head1 RECONNECTION

When C<reconnect> is enabled on the Redis connection, subscriptions are
automatically re-established after a connection drop. To be notified:

    $sub->on_reconnect(sub {
        my ($sub) = @_;
        warn "Reconnected, may have lost messages";
        # re-poll state, log, etc.
    });

Messages published while the connection was down are lost (Redis pub/sub
has no persistence).

=head1 CALLBACK-DRIVEN DELIVERY

As an alternative to the C<await $sub-E<gt>next> iterator, you can
register a callback to receive messages:

    my $sub = await $redis->subscribe('chat');
    $sub->on_message(sub {
        my ($sub, $msg) = @_;
        # $msg has the same shape as next() returns:
        #   { type => 'message'|'pmessage'|'smessage',
        #     channel => ...,
        #     pattern => ...,  # defined for pmessage, undef otherwise
        #     data    => ... }
    });

Callback mode is designed for fire-and-forget listeners — background
dispatchers, websocket gateways, channel-layer middleware — where the
iterator pattern's requirement to be inside an awaited async sub is
awkward or triggers Future::AsyncAwait "lost its returning future"
warnings.

=head2 Exclusivity

Once C<on_message> is set on a Subscription, it is callback-mode for
the rest of its lifetime. Calls to C<< $sub->next >> will C<croak>.
This is sticky — there is no way to switch back. If you need iterator
mode, construct a new Subscription.

=head2 Signature

    $sub->on_message(sub {
        my ($subscription, $message) = @_;
        ...
    });

The callback receives the C<$subscription> itself as its first argument
(consistent with C<on_reconnect>), and the message hashref as its
second. The return value is normally ignored; if the return is a
C<Future>, see L</Backpressure>.

=head2 Backpressure

If your callback returns a C<Future>, the driver waits for that Future
to resolve before reading the next frame:

    $sub->on_message(async sub {
        my ($sub, $msg) = @_;
        await store_to_database($msg);    # driver waits before next read
    });

Synchronous callbacks (or callbacks returning non-Future values) do not
block the driver. This gives consumers opt-in backpressure with no
default overhead.

If the returned Future fails, the failure is routed to C<on_error>.

=head2 Fatal error handling

    $sub->on_error(sub {
        my ($sub, $err) = @_;
        ...
    });

C<on_error> fires when the underlying read encounters an error that
cannot be recovered by reconnect (e.g., reconnect is disabled, or
reconnect itself failed). After C<on_error> fires, the subscription is
closed and the driver stops.

B<If C<on_error> is not registered, fatal errors C<die>.> Silent death
of a pub/sub consumer is a debugging nightmare; loud-by-default
prevents it. If you genuinely want to swallow errors, register an
explicit no-op: C<< $sub->on_error(sub { }) >>.

Callback exceptions (dying inside C<on_message>) are also routed to
C<on_error>; the callback-died message is prepended to the error
string.

=head2 Ordering guarantee

Callbacks fire in the order frames arrive on the connection. No
concurrent invocation (Perl is single-threaded and the driver runs on
the event loop). After a reconnect, C<on_reconnect> always fires before
any post-reconnect C<on_message>.

=head2 Re-entrancy

Inside an C<on_message> callback you may safely:

=over 4

=item * Call C<< $sub->subscribe(...) >> — the new channel is added
cleanly; messages on it arrive via the same callback.

=item * Call C<< $sub->on_message($new_cb) >> — the current message is
dispatched to the previously-installed handler; the next frame uses
the new handler.

=item * C<die> — routed to C<on_error>.

=back

=head2 Backpressure and Redis server limits

Synchronous callbacks provide backpressure by blocking the driver loop:
while your callback runs, the driver doesn't read the next frame, so
TCP fills, Redis's output buffer grows. But Redis enforces
C<client-output-buffer-limit pubsub> (defaulting to S<32mb 8mb 60>
in recent versions) — if your subscriber cannot keep up for sustained
periods, B<Redis will disconnect you>. There is no amount of
client-side buffering that changes this: the limit is on the server.

If your processing is genuinely slow, return a Future from your
callback (enabling opt-in backpressure above) AND consider moving the
expensive work to a worker pool so the callback can return quickly.
Long synchronous processing in pub/sub callbacks is an anti-pattern at
scale regardless of client.

=head1 INTERNAL LIFECYCLE METHODS

The following methods are used by L<Async::Redis> to manage subscription
state. They are not part of the public API for end consumers, but are
documented here for maintainers.

=head2 _close

Intentional teardown. Marks the subscription closed and wakes any
blocked C<next()> with C<undef>. Clears the parent C<_subscription>
slot on the L<Async::Redis> object with an identity guard — a stale
C<_close> call from an earlier subscription object cannot evict a newer
one that has since taken the slot.

=head2 _fail_fatal($typed_error)

Unrecoverable failure. Marks the subscription closed with a typed error
object. Any blocked C<next()> call will C<die> with that error. The
error is preserved for callers who call C<next()> after the fact.
Routes through C<_close>'s identity guard for parent-slot clearing.

=head2 _pause_for_reconnect

Called before a reconnect attempt. Does B<not> mark the subscription
closed — the underlying reader has already exited due to the connection
drop. Channel/pattern tracking hashes are left intact for replay.

=head2 _resume_after_reconnect

Async. Replays all tracked C<SUBSCRIBE>, C<PSUBSCRIBE>, and
C<SSUBSCRIBE> commands on the freshly reconnected socket. Sets
C<in_pubsub=1> before sending replay commands so that racing message
frames classify correctly (mirrors the timing of the initial
subscribe). Fires C<on_reconnect> after replay, then restarts the read
driver.

=cut
