package Spot::EventEmitter::State;

use Mojo::Base qw(Mojo::EventEmitter);

use JSON;

sub track {
    my $self = shift;
    my $track = shift;

    return unless $track;

    my $track_info = $self->app->redis->hget('cache.tracks', $track);
    if ($track_info) {
        $track = decode_json $track_info;
    }

    $self->emit(track_change => $track);
}

sub playlist {
    my $self = shift;

    $self->emit(playlist_update => 1);
}

sub user {
    my $self = shift;
    my $user_id = shift;
    my $status = shift;

    return unless $user_id;

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
    say "[DEBUG] Firing state update event";

    $self->emit(update => $update);
}

1;
