package Async::Redis::Connection;

use strict;
use warnings;
use 5.018;

use Future;
use Future::AsyncAwait;
use Future::IO qw(POLLIN POLLOUT);
use Errno qw(EAGAIN EWOULDBLOCK);
use Scalar::Util qw(blessed refaddr weaken);
use Time::HiRes ();
use Carp ();

use Async::Redis::Error::Connection;
use Async::Redis::Error::Disconnected;
use Async::Redis::Error::Protocol;
use Async::Redis::Error::Timeout;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        client        => $args{client},
        socket        => $args{socket},
        parser        => Async::Redis::_parser_class()->new(api => 1),
        pid           => $args{pid} // $$,   # the process that opened the socket
        closed        => 0,
        close_error   => undef,
        in_pubsub     => 0,

        # Server-side transaction state of this connection: MULTI open,
        # keys watched. A new connection starts with neither.
        in_multi      => 0,
        watching      => 0,

        # Entry: { future, cmd, args, deadline, redis_error, sent_at }
        inflight      => [],

        # Futures this connection owns; close cancels or fails each.
        reader        => undef,   # the reader task
        read_f        => undef,   # the reader's pending read
        write_f       => undef,   # the pending write
        gate          => undef,   # the write gate's current lock

        auto_pipeline => undef,
    }, $class;

    # The client owns its connections, not the other way round.
    weaken($self->{client});

    return $self;
}

sub is_closed      { $_[0]{closed} }
sub close_error    { $_[0]{close_error} }
sub pid            { $_[0]{pid} }
sub socket         { $_[0]{socket} }
sub parser         { $_[0]{parser} }
sub inflight_count { scalar @{ $_[0]{inflight} // [] } }

sub in_pubsub {
    my $self = shift;
    $self->{in_pubsub} = $_[0] ? 1 : 0 if @_;
    return $self->{in_pubsub};
}

# Register $entries and write $raw, holding the write gate so inflight
# order matches wire order. Resolves once the write completes; the entries'
# futures resolve as their replies arrive.
async sub submit {
    my ($self, $raw, $entries) = @_;

    if ($self->{pid} != $$) {
        $self->_forked;
        die $self->{close_error};
    }
    die $self->{close_error} if $self->{closed};

    my $lock = await $self->_acquire_gate;

    my $now = Time::HiRes::time();
    for my $entry (@$entries) {
        $entry->{redis_error} //= 'fail';
        $entry->{sent_at}       = $now;
        push @{$self->{inflight}}, $entry;
    }

    my $ok  = eval { await $self->_send($raw); 1 };
    my $err = $@;

    # Closed while writing: the write was cancelled by close, and the
    # caller gets the close error, not the cancellation.
    if ($self->{closed}) {
        $self->_release_gate($lock);
        die $self->{close_error};
    }

    if (!$ok) {
        my $typed = Async::Redis::Error::Connection->new(
            message => "Write failed: $err",
            $self->_endpoint,
        );
        # Close before releasing the gate, so no waiter writes to a
        # connection that is already known to be broken.
        $self->_fail($typed);
        $self->_release_gate($lock);
        die $typed;
    }

    $self->_release_gate($lock);
    $self->_ensure_reader;
    return;
}

# The single teardown. Idempotent and never throws: it runs from futures'
# completion callbacks, where an exception would break the event loop.
sub close {
    my ($self, $err) = @_;
    return if $self->{closed};

    # A forked child shares the parent's socket. Cancelling or shutting it
    # down here would act on the parent's connection, and the work it holds
    # fails with the forked error whatever closed it.
    if ($self->{pid} != $$) {
        $self->abandon;
        return;
    }

    # 1. Every later submit fails with $err.
    $self->{closed}      = 1;
    $self->{close_error} = $err;

    # 2. Detach inflight entries so they fail with $err, not a cancellation.
    my @detached = @{$self->{inflight}};
    $self->{inflight} = [];
    if (my $ap = $self->{auto_pipeline}) {
        push @detached, @{ $ap->_detach_queued };
    }

    # 3. Cancel the pending read and write, and the reader, while the
    #    socket's fileno is still valid for Future::IO to unregister.
    for my $slot (qw(read_f write_f reader)) {
        my $f = delete $self->{$slot} or next;
        _reporting_exceptions(sub { $f->cancel unless $f->is_ready });
    }

    # 4. Submitters holding or waiting on the gate unwind with $err.
    if (my $lock = delete $self->{gate}) {
        _reporting_exceptions(sub { $lock->fail($err) unless $lock->is_ready });
    }

    # 5. shutdown, never close(): DESTROY of the handle closes it.
    if (my $socket = $self->{socket}) {
        shutdown($socket, 2) if defined fileno($socket);
    }

    # 6.
    for my $entry (@detached) {
        my $f = $entry->{future};
        _reporting_exceptions(sub { $f->fail($err) unless $f->is_ready });
    }

    return;
}

# Tell the client this connection is gone, and close it with $err. The
# client is told once, by whichever failure ends the connection, and is
# told before the close: closing runs the waiting callers' code, which must
# already see the client disconnected (so a retry there reconnects).
sub _fail {
    my ($self, $err) = @_;
    return if $self->{closed};

    # In a forked child this is not a lost connection: no on_disconnect,
    # no reconnect, no resubscribe.
    if ($self->{pid} != $$) {
        $self->_forked;
        return;
    }

    if (my $client = $self->{client}) {
        $client->_connection_lost($self, $err);
    }
    $self->close($err);
    return;
}

# The teardown in a process that did not open the socket: the client
# drops what it inherited, and this connection fails the work it holds.
sub _forked {
    my ($self) = @_;
    if (my $client = $self->{client}) {
        $client->_check_fork;
    }
    $self->abandon;
    return;
}

sub _forked_error {
    return Async::Redis::Error::Disconnected->new(
        message => "Connection belongs to the process that forked this one",
    );
}

# Fail the commands this connection holds with the forked error, and drop
# everything without cancelling or shutting down: the socket and the
# event-loop watches on it belong to the process that made this connection.
# Idempotent.
sub abandon {
    my ($self) = @_;
    $self->{closed}        = 1;
    $self->{close_error} //= _forked_error();
    my $err = $self->{close_error};

    my @detached = @{ $self->{inflight} // [] };
    $self->{inflight} = [];
    if (my $ap = $self->{auto_pipeline}) {
        push @detached, @{ $ap->_detach_queued };
    }
    my $lock = $self->{gate};
    delete @{$self}{qw(socket parser reader read_f write_f gate auto_pipeline)};

    # Submitters waiting on the gate unwind with $err.
    _reporting_exceptions(sub { $lock->fail($err) unless $lock->is_ready })
        if $lock;
    for my $entry (@detached) {
        my $f = $entry->{future};
        _reporting_exceptions(sub { $f->fail($err) unless $f->is_ready });
    }
    return;
}

sub DESTROY {
    my ($self) = @_;
    return unless $self->{pid} == $$;
    my $socket = $self->{socket} or return;
    shutdown($socket, 2) if defined fileno($socket);
}

# Run $code, reporting rather than throwing anything it dies with. Failing
# or cancelling a future runs its callbacks, and a user callback may die.
sub _reporting_exceptions {
    my ($code) = @_;
    local $@;
    eval { $code->(); 1 }
        or Carp::carp("Async::Redis error while closing a connection: $@");
    return;
}

# Resolve $entry's future with its reply. That runs the caller's code
# attached to it (on_done, on_fail, then ...); if that code dies, the
# error is the caller's, so it is reported and the reader carries on
# with the other commands' replies.
sub _deliver {
    my ($entry, $method, @value) = @_;
    my $f = $entry->{future};
    return if $f->is_ready;
    local $@;
    eval { $f->$method(@value); 1 }
        or Carp::carp("Async::Redis: a callback on a command's reply died: $@");
    return;
}

sub _endpoint {
    my ($self) = @_;
    my $client = $self->{client};
    return (
        host => $client ? $client->{host} : undef,
        port => $client ? $client->{port} : undef,
    );
}

# The write gate. Each holder installs its own lock future; later
# submitters wait for it in turn.
async sub _acquire_gate {
    my ($self) = @_;
    while (my $held = $self->{gate}) {
        await $held;
    }
    die $self->{close_error} if $self->{closed};
    return $self->{gate} = Future->new;
}

sub _release_gate {
    my ($self, $lock) = @_;
    delete $self->{gate}
        if $self->{gate} && refaddr($self->{gate}) == refaddr($lock);
    $lock->done unless $lock->is_ready;
    return;
}

# Future::IO reports readiness; the connection does the socket I/O itself,
# after checking it is in the process that opened the socket. A forked
# child's event loop holds the parent's pending polls, and I/O done inside
# Future::IO's own readiness callback would let the child take the
# parent's reply or send the parent's command a second time.

# Wait until the socket is ready for $events, then run $io->($self, $f).
# In another process, take the forked teardown and fail $f with the close
# error instead. Cancelling $f cancels the poll.
sub _when_ready {
    my ($self, $events, $f, $io) = @_;
    my $poll = Future::IO->poll($self->{socket}, $events);
    $f //= $poll->new;
    $f->on_cancel($poll);

    weaken(my $weak_self = $self);
    $poll->on_done(sub {
        return if $f->is_ready;
        my $self = $weak_self or return;
        if ($self->{pid} != $$) {
            $self->_forked;
            $f->fail($self->{close_error});
            return;
        }
        $io->($self, $f);
    });
    return $f;
}

# Up to $length bytes, as Future::IO->read gives them: the bytes, an empty
# done on EOF, or a failure.
sub _read_some {
    my ($self, $length, $f) = @_;
    my $socket = $self->{socket};
    return $self->_when_ready(POLLIN, $f, sub {
        my ($self, $f) = @_;
        my $n = $socket->sysread(my $buf, $length);
        if ($n) {
            $f->done($buf);
        }
        elsif (defined $n) {
            $f->done;
        }
        elsif ($! == EAGAIN || $! == EWOULDBLOCK) {
            $self->_read_some($length, $f);
        }
        else {
            $f->fail("sysread: $!\n", sysread => $socket, $!);
        }
    });
}

# Write all of $data, as Future::IO->write_exactly does.
sub _write_all {
    my ($self, $data, $f) = @_;
    my $socket = $self->{socket};
    return $self->_when_ready(POLLOUT, $f, sub {
        my ($self, $f) = @_;
        my $n = $socket->syswrite($data);
        if (defined $n) {
            substr($data, 0, $n, '');
            return $f->done unless length $data;
        }
        elsif ($! != EAGAIN && $! != EWOULDBLOCK) {
            return $f->fail("syswrite: $!\n", syswrite => $socket, $!);
        }
        $self->_write_all($data, $f);
    });
}

sub _send {
    my ($self, $data) = @_;
    my $write_f = $self->_write_all($data);
    $self->{write_f} = $write_f;
    weaken(my $weak_self = $self);
    $write_f->on_ready(sub {
        return unless $weak_self && $weak_self->{write_f};
        delete $weak_self->{write_f}
            if refaddr($weak_self->{write_f}) == refaddr($write_f);
    });
    return $write_f;
}

# Start the reader unless one is running.
#
# The reader only fails when nothing else will report the error: an
# unhandled exception in the reader, or one raised while handling a
# failure (a user callback such as on_disconnect that died). So it is
# reported here as a warning. Nothing may be thrown from this handler: it
# runs inside the event loop's completion handling, and an exception there
# breaks the loop for every connection sharing it.
sub _ensure_reader {
    my ($self) = @_;
    return if $self->{reader} || $self->{closed};

    my $reader = $self->_run_reader;
    $self->{reader} = $reader;

    weaken(my $weak_self = $self);
    $reader->on_ready(sub {
        return unless $weak_self && $weak_self->{reader};
        delete $weak_self->{reader}
            if refaddr($weak_self->{reader}) == refaddr($reader);
    });
    $reader->on_fail(sub {
        my ($err) = @_;
        chomp(my $reason = "$err");
        Carp::carp("Async::Redis reader stopped: $reason");
        return unless $weak_self;
        my $typed = (ref $err && eval { $err->isa('Async::Redis::Error') })
            ? $err
            : Async::Redis::Error::Connection->new(
                message => "Reader failed: $reason",
                $weak_self->_endpoint,
            );
        local $@;
        my $ok = eval { $weak_self->_fail($typed); 1 };
        Carp::carp("Async::Redis error while handling reader failure: "
            . ($@ // 'unknown error')) unless $ok;
    });

    return;
}

# The reader stops on a stream failure. It clears its own slot first, so
# that close never cancels the task that is running it.
sub _reader_lost {
    my ($self, $err) = @_;
    delete $self->{reader};
    $self->_fail($err);
    return;
}

# The single socket reader. Runs while there is work: inflight entries, or
# pub/sub with a live subscription.
async sub _run_reader {
    my ($self) = @_;

    while (1) {
        return if $self->{closed};
        return unless $self->{client};
        last if !$self->{in_pubsub} && !@{$self->{inflight}};
        last if $self->{in_pubsub} && !$self->{client}{_subscription};

        my $head     = $self->{inflight}[0];
        my $deadline = $head ? $head->{deadline} : undef;

        my $read_f = $self->_read_some(65536);
        $self->{read_f} = $read_f;

        my ($returned_f, $timed_out)
            = await Async::Redis::_await_with_deadline($read_f, $deadline);

        return if $self->{closed};

        # On timeout the read is still pending; close cancels it.
        delete $self->{read_f} unless $timed_out;

        if ($timed_out) {
            my $client = $self->{client};
            $self->_reader_lost(Async::Redis::Error::Timeout->new(
                message        => "Request timed out",
                command        => $head ? $head->{args} : undef,
                timeout        => $client ? $client->{request_timeout} : undef,
                maybe_executed => 1,
            ));
            return;
        }

        if ($returned_f->is_failed) {
            my ($rerr) = $returned_f->failure;
            $self->_reader_lost(Async::Redis::Error::Connection->new(
                message => "Connection read error: $rerr",
                $self->_endpoint,
            ));
            return;
        }

        my $buf = $returned_f->get;
        if (!defined $buf || length($buf) == 0) {
            $self->_reader_lost(Async::Redis::Error::Connection->new(
                message => "Connection closed by peer",
                $self->_endpoint,
            ));
            return;
        }

        $self->{parser}->parse($buf);

        # Drain all complete messages the parser has. Dispatching a reply runs
        # the caller's continuation synchronously, and that code may tear the
        # connection down (disconnect, or a fatal), so re-check before each
        # message, as the outer loop does before each read.
        while (!$self->{closed} and my $msg = $self->{parser}->get_message) {
            my $client = $self->{client} or return;
            my ($kind, $value) = $client->_decode_response_result($msg);

            if ($kind eq 'protocol_error') {
                $self->_reader_lost($value);
                return;
            }

            my $is_pubsub_message = 0;
            if ($self->{in_pubsub} && $kind eq 'ok' && ref($value) eq 'ARRAY') {
                my $frame_name = $value->[0] // '';
                $is_pubsub_message = 1
                    if $frame_name eq 'message'
                    || $frame_name eq 'pmessage'
                    || $frame_name eq 'smessage';
            }

            if ($is_pubsub_message) {
                my $sub = $client->{_subscription};
                if (!$sub) {
                    # No active subscription but got a message frame: strict desync.
                    $self->_reader_lost(Async::Redis::Error::Protocol->new(
                        message => "message frame but no active subscription",
                    ));
                    return;
                }
                # _dispatch_frame returns a Future when the message queue is
                # full (backpressure); wait for room before reading on.
                my $dispatch_result = $sub->_dispatch_frame($value);
                if (blessed($dispatch_result) && $dispatch_result->isa('Future')) {
                    await $dispatch_result;
                }
                next;
            }

            if (!@{$self->{inflight}}) {
                # Strict: unexpected frame with empty inflight = desync.
                $self->_reader_lost(Async::Redis::Error::Protocol->new(
                    message => "unexpected frame (kind=$kind) with empty inflight",
                ));
                return;
            }

            my $entry = shift @{$self->{inflight}};
            if ($kind eq 'redis_error') {
                if (($entry->{redis_error} // 'fail') eq 'capture') {
                    _deliver($entry, done => $value);
                } else {
                    _deliver($entry, fail => $value);
                }
            } else {
                _deliver($entry, done => $value);
            }
        }
    }
}

1;

__END__

=head1 NAME

Async::Redis::Connection - One Redis connection and everything started on it

=head1 DESCRIPTION

Internal to L<Async::Redis>; not a public API.

A connection owns one socket and all the state and work that exist only
while that socket does: the RESP parser, the inflight queue, the write
gate, the reader task, the reader's pending read, the pending write,
whether it is in pub/sub mode, the pid of the process that made it, and
(when C<auto_pipeline> is on) its auto-pipeline.

The client holds at most one current connection and reaches the network
only through it. A submitter takes the current connection once and does
all its work on that object, so work left over from a closed connection
can only ever act on that closed connection.

The connection holds its client weakly. It uses the client to decode
replies, to dispatch pub/sub messages, and to report its own loss
(C<_connection_lost>), which the client ignores for any connection that
is no longer current.

=head2 Submitting

C<submit($raw, \@entries)> waits for the write gate, registers the
entries in the inflight queue, writes C<$raw>, and starts the reader.
Registering before writing keeps inflight order equal to wire order,
which is how each reply is matched to its caller. If the connection is
closed before or during the write, C<submit> fails with the close error.

=head2 Closing

C<close($err)> is the only teardown. It is idempotent and never throws.
In order, it:

=over 4

=item 1. marks the connection closed, so every later C<submit> fails with C<$err>;

=item 2. detaches the inflight entries and the auto-pipeline's queued commands;

=item 3. cancels the pending read, the pending write and the reader, while the socket's fileno is still valid;

=item 4. fails the write gate, so submitters holding or waiting on it unwind with C<$err>;

=item 5. shuts the socket down (never C<close()>; the handle closes when it is freed);

=item 6. fails every detached entry with C<$err>.

=back

C<_fail($err)> reports the loss to the client, once, and closes the
connection. The client disconnects itself and then closes the
connection, so the callers that closing wakes already see the client
disconnected. The reader uses it for every stream failure (EOF, read
error, deadline, protocol error), and C<submit> for a write failure.

=head2 Transaction state

C<in_multi> and C<watching> record the server's MULTI and WATCH state for
this connection; a new connection starts with neither. While either is
set the client pins this connection (C<_transaction_connection>), so a
transaction's commands can only ever go to the connection it started on.

=head2 Handshake

The client's handshake (AUTH, SELECT, CLIENT SETNAME) is submitted like
any command and read by this connection's reader. The connection is the
client's current one during the handshake, but the client hands it to
callers only once the handshake has succeeded.

=head2 Fork

The connection belongs to the process that opened its socket (C<pid>).
A forked child shares that socket, and its event loop holds every poll
and timer the parent had pending. So Future::IO only reports readiness,
and the connection reads and writes the socket itself after checking the
process: Future::IO, doing the I/O in its own readiness callback, would
let the child take the parent's replies and send the parent's commands a
second time.

In another process, every entry point (a read or write becoming ready,
C<submit>, C<_fail>, C<close>) takes the same teardown, C<abandon>: the
commands this connection holds, including queued auto-pipeline ones,
fail with an L<Async::Redis::Error::Disconnected> naming the fork, and
references are dropped. Nothing is done on the socket: no read, write,
cancel or shutdown. C<DESTROY> there does nothing. Losing the connection
in a child is not a disconnect: the client's C<on_disconnect>, reconnect
and resubscribe never run for it.

=cut
