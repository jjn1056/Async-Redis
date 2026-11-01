package Async::Redis::Error;

use strict;
use warnings;
use 5.018;

use overload
    '""'     => 'stringify',
    bool     => sub { 1 },
    fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message { shift->{message} }

sub stringify {
    my ($self) = @_;
    return $self->message // ref($self) . ' error';
}

sub throw {
    my $self = shift;
    $self = $self->new(@_) unless ref $self;
    die $self;
}

1;

__END__

=head1 NAME

Async::Redis::Error - Base exception class for Redis errors

=head1 SYNOPSIS

    use Async::Redis::Error;

    # Create and throw
    Async::Redis::Error->throw(message => 'something went wrong');

    # Or create and die later
    my $error = Async::Redis::Error->new(message => 'oops');
    die $error;

    # Catch
    eval { ... };
    if ($@ && $@->isa('Async::Redis::Error')) {
        warn "Redis error: " . $@->message;
    }

=head1 DESCRIPTION

Base class for all Async::Redis exceptions. Subclasses provide
specific error types with additional context.

=head1 METHODS

=head2 new

    my $error = Async::Redis::Error->new(message => 'oops', %context);

Builds an error from its fields. C<message> is the text; subclasses
take further fields (see each one's ATTRIBUTES).

=head2 throw

    Async::Redis::Error->throw(message => 'oops');
    $error->throw;

Dies with the error: called on the class, builds one from the arguments
first.

=head2 message

The error text.

=head2 stringify

The error as a string: its C<message>, or the class name if it has none.
An error also stringifies this way in string context.

=cut
