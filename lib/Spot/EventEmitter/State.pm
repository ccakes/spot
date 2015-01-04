package Spot::EventEmitter::State;

use Mojo::Base qw(Mojo::EventEmitter);

sub update {
    my $self = shift;
    my $update = shift;

    return unless $update;
    say "[DEBUG] Firing state update event";

    $self->emit(update => $update);
}

1;
