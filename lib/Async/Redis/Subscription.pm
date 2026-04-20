package Async::Redis::Subscription;

use strict;
use warnings;
use 5.018;

use Carp ();
use Future;
use Future::AsyncAwait;

our $VERSION = '0.001';

sub new {
    my ($class, %args) = @_;

    return bless {
        redis            => $args{redis},
        channels         => {},      # channel => 1 (for regular subscribe)
        patterns         => {},      # pattern => 1 (for psubscribe)
        sharded_channels => {},      # channel => 1 (for ssubscribe)
        _message_queue   => [],      # Buffer for messages
        _waiters         => [],      # Futures waiting for messages
        _on_reconnect    => undef,   # Callback for reconnect notification
        _on_message      => undef,   # Message-arrived callback (Task 3)
        _on_error        => undef,   # Fatal-error callback (Task 3)
        _closed          => 0,
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
        $self->{_on_message} = $cb;
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
# Returns the callback's return value (which may be a Future — used
# for consumer-side backpressure in the driver loop added later).
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
}

sub _add_pattern {
    my ($self, $pattern) = @_;
    $self->{patterns}{$pattern} = 1;
}

sub _add_sharded_channel {
    my ($self, $channel) = @_;
    $self->{sharded_channels}{$channel} = 1;
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

# Receive next message (async iterator pattern)
async sub next {
    my ($self) = @_;

    return undef if $self->{_closed};

    # Exclusivity check: callback mode disables iterator mode.
    # (The _on_message slot is initialized in new(); inert until Task 3.)
    if ($self->{_on_message}) {
        Carp::croak("Cannot call next() on a callback-driven subscription");
    }

    if (@{$self->{_message_queue}}) {
        return shift @{$self->{_message_queue}};
    }

    while (1) {
        my $frame = await $self->_read_frame_with_reconnect;
        last unless $frame;
        $self->_dispatch_frame($frame);
        # _dispatch_frame buffers the message into _message_queue (when
        # on_message is unset — which it must be in this branch since
        # the exclusivity check above throws otherwise). Pull from queue.
        if (@{$self->{_message_queue}}) {
            return shift @{$self->{_message_queue}};
        }
        # Otherwise it was a non-message frame; loop for another.
    }

    return undef;
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
                my $reconnect_ok = eval {
                    await $redis->_reconnect_pubsub;
                    1;
                };
                unless ($reconnect_ok) {
                    die $error;
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
# When on_message is set (callback mode), invoke the callback via
# _invoke_user_callback and return its result (which may be a Future
# for consumer-side backpressure). Otherwise buffer the message via
# _deliver_message for next()/iterator consumers and return undef.
#
# Non-message frames (subscribe confirmations, etc.) return undef and
# take no action — the caller's loop will read another frame.
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
        return undef;   # non-message frame
    }

    if (my $cb = $self->{_on_message}) {
        return $self->_invoke_user_callback($cb, $msg);
    }

    $self->_deliver_message($msg);
    return undef;
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

# Internal: called when message arrives
sub _deliver_message {
    my ($self, $msg) = @_;

    if (@{$self->{_waiters}}) {
        # Someone is waiting - deliver directly
        my $waiter = shift @{$self->{_waiters}};
        $waiter->done($msg);
    }
    else {
        # Buffer the message
        push @{$self->{_message_queue}}, $msg;
    }
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

# Close subscription
sub _close {
    my ($self) = @_;

    $self->{_closed} = 1;
    $self->{redis}{in_pubsub} = 0;

    # Cancel any waiters
    for my $waiter (@{$self->{_waiters}}) {
        $waiter->done(undef) unless $waiter->is_ready;
    }
    $self->{_waiters} = [];
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

=cut
