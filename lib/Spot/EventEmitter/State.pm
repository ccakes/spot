package Spot::EventEmitter::State;

use Mojo::Base qw(Mojo::EventEmitter);

use JSON;
use Time::Piece;

sub track {
    my $self = shift;
    my $spot = shift;
    my $redis = shift;

    # Application-level change
    # Push new state to Redis
    my $state = $spot->status;
    $redis->set('cache.state', encode_json $state);

    say "[" . localtime->datetime . ":DEBUG] Firing State::track()";
    $self->emit(track_change => 1);
}

sub playlist {
    my $self = shift;

    say "[" . localtime->datetime . ":DEBUG] Firing State::playlist()";
    $self->emit(playlist_update => 1);
}

sub user {
    my $self = shift;
    my $user_id = shift;
    my $status = shift;

    return unless $user_id;
    say "[" . localtime->datetime . ":DEBUG] Firing State::user($status)";

    if ($status) {
        $self->emit(user_joined => $user_id);
    } else {
        $self->emit(user_left => $user_id);
    }
}

sub update {
    my $self = shift;
    my $update = shift;

    return unless $update;
    say "[" . localtime->datetime . ":DEBUG] Firing State::update()";

    $self->emit(update => $update);
}

1;
