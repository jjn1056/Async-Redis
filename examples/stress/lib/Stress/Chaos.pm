package Stress::Chaos;
use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

sub new {
    my ($class, %args) = @_;
    return bless {
        controller      => $args{controller},
        targets         => $args{targets},          # arrayref of [name => client]
        interval        => $args{interval}        // 30,
        recovery_window => $args{recovery_window} // 5,
        integrity       => $args{integrity},
        running         => 1,
        kills_issued    => 0,
        last_victim     => undef,
    }, $class;
}

async sub run {
    my ($self) = @_;
    while ($self->{running}) {
        await Future::IO->sleep($self->{interval});
        last unless $self->{running};

        my @candidates = grep {
            my $client = $_->[1];
            $client->{connected} && $client->{socket};
        } @{ $self->{targets} };
        next unless @candidates;

        my $pick = $candidates[ int rand @candidates ];
        my ($name, $victim) = @$pick;
        my $sock = $victim->{socket};
        my $addr = $sock->sockhost . ':' . $sock->sockport;

        eval { await $self->{controller}->client('KILL', 'ADDR', $addr) };
        $self->{kills_issued}++;
        $self->{last_victim} = $name;
        $self->{integrity}->enter_chaos_window($self->{recovery_window})
            if $self->{integrity};
    }
    return;
}

sub stop {
    my ($self) = @_;
    $self->{running} = 0;
    return;
}

sub snapshot {
    my ($self) = @_;
    return {
        kills_issued => $self->{kills_issued},
        last_victim  => $self->{last_victim},
    };
}

1;
