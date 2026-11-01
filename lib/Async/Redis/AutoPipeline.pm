package Async::Redis::AutoPipeline;

use strict;
use warnings;
use 5.018;

use Future;
use Future::AsyncAwait;
use Future::IO;
use Scalar::Util qw(refaddr weaken);
use Async::Redis::Error::Disconnected;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        redis         => $args{redis},
        connection    => $args{connection},
        max_depth     => $args{max_depth} // 1000,
        _queue        => [],
        _flush_pending => 0,
        _flushing     => 0,
        _submits      => {},   # in-flight submit futures, by refaddr
    }, $class;

    # The connection owns this auto-pipeline, and the client owns the
    # connection.
    weaken($self->{redis});
    weaken($self->{connection});

    return $self;
}

sub command {
    my ($self, @args) = @_;

    my $future = Future->new;
    push @{$self->{_queue}}, { cmd => \@args, future => $future };

    # Schedule flush exactly once per batch
    unless ($self->{_flush_pending}) {
        $self->{_flush_pending} = 1;
        $self->_schedule_flush;
    }

    return $future;
}

sub _schedule_flush {
    my ($self) = @_;

    # Use event loop's "next tick" mechanism
    # sleep(0) yields to event loop then immediately returns
    Future::IO->sleep(0)->on_done(sub {
        $self->_do_flush;
    });
}

sub _do_flush {
    my ($self) = @_;

    # Reentrancy guard
    return if $self->{_flushing};
    $self->{_flushing} = 1;

    # Reset pending flag before flush (allows new commands to queue)
    $self->{_flush_pending} = 0;

    # Take current queue atomically
    my @batch = splice @{$self->{_queue}};

    if (@batch) {
        # Respect depth limit
        my $max = $self->{max_depth};
        if (@batch > $max) {
            # Put excess back, schedule another flush
            unshift @{$self->{_queue}}, splice(@batch, $max);
            $self->{_flush_pending} = 1;
            $self->_schedule_flush;
        }

        $self->_send_batch(\@batch);
    }

    $self->{_flushing} = 0;
}

# Detach and return all queued-but-not-yet-flushed commands. Caller is
# responsible for failing their futures. Called by the connection's close
# when it closes before a scheduled flush.
sub _detach_queued {
    my ($self) = @_;
    my $queued = $self->{_queue} // [];
    $self->{_queue} = [];
    $self->{_flush_pending} = 0;
    return $queued;
}

sub _send_batch {
    my ($self, $batch) = @_;
    my $redis = $self->{redis};
    my $conn  = $self->{connection};

    my @futures = map { $_->{future} } @$batch;

    my $submit;
    if ($redis && $conn) {
        my $buffer = '';
        my @entries;
        for my $queued (@$batch) {
            my $cmd = $queued->{cmd};
            $buffer .= $redis->_build_command(@$cmd);
            push @entries, {
                future      => $queued->{future},
                cmd         => $cmd->[0],
                args        => [ @{$cmd}[1 .. $#$cmd] ],
                deadline    => $redis->_calculate_deadline(@$cmd),
                redis_error => 'fail',
            };
        }
        $submit = $conn->submit($buffer, \@entries);
    }
    else {
        $submit = Future->fail(Async::Redis::Error::Disconnected->new(
            message => "Not connected",
        ));
    }

    # A submit failure (the connection closed, or the write failed) reaches
    # every future in the batch the connection did not already fail.
    $submit->on_fail(sub {
        my ($err) = @_;
        for my $f (@futures) {
            $f->fail($err) unless $f->is_ready;
        }
    });

    # Nobody else holds the submit while it runs, so this auto-pipeline
    # does, until it is ready; otherwise it would be freed mid-write and
    # its commands would never complete.
    my $key = refaddr($submit);
    $self->{_submits}{$key} = $submit;
    weaken(my $weak_self = $self);
    $submit->on_ready(sub { delete $weak_self->{_submits}{$key} if $weak_self });
}

1;

__END__

=head1 NAME

Async::Redis::AutoPipeline - Automatic command batching

=head1 DESCRIPTION

Internal to L<Async::Redis>; not a public API: turn it on with Async::Redis's C<auto_pipeline> option.

AutoPipeline transparently batches Redis commands issued in the same
event loop tick into a single pipeline, reducing network round-trips
without changing the caller's API.

=head2 How It Works

    # These three commands are batched automatically
    my $f1 = $redis->set('a', 1);
    my $f2 = $redis->set('b', 2);
    my $f3 = $redis->get('a');

    await Future->needs_all($f1, $f2, $f3);

When C<auto_pipeline =E<gt> 1>:

=over 4

=item 1.

Commands queue locally instead of sending immediately.

=item 2.

A next-tick flush is scheduled with C<< Future::IO->sleep(0) >>.

=item 3.

When the event loop yields, queued commands flush as a pipeline.

=item 4.

Responses are distributed to the original command futures.

=back

=head2 Invariants

=over 4

=item * C<_flush_pending> prevents double-scheduling

=item * C<_flushing> guard prevents reentrancy

=item * Depth limit triggers multiple batches if exceeded

=item * C<< Future::IO->sleep(0) >> provides the non-blocking yield point

=back

=cut
