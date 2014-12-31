package SpotifyLocal::Controller::Main;

use Mojo::Base 'Mojolicious::Controller';

use JSON;

use Data::Dumper::Simple;

sub main {
    my $self = shift;

    my $status = $self->spot->status;
    my $title = 'Not Playing';
    my $artist = 'Not Playing';
    my ($track, $album, $artist_id);
    my $background = '/default.jpg';

    if ($status->{track}) {
        $title = sprintf '%s - %s', $status->{track}->{artist_resource}->{name}, $status->{track}->{track_resource}->{name};

        $artist = $status->{track}->{artist_resource}->{name};
        $track = $status->{track}->{track_resource}->{name};
        $album = $status->{track}->{album_resource}->{name};

        $artist_id = (split /\:/, $status->{track}->{artist_resource}->{uri})[2];

        my $ua = Mojo::UserAgent->new;
        my $res = $ua->get('https://api.spotify.com/v1/artists/' . $artist_id, {'Accept' => 'application/json'})->res;

        $background = $res->json->{images}->[0]->{url};
    }

    $self->render('main', title => $title, artist => $artist, album => $album, track => $track, background => $background, artist_id => $artist_id);

}

sub status {
    my $self = shift;

    my $status = $self->spot->status;

    $status->{playlist} = $self->redis->lrange('playlist.main', 0, 100);

    $self->render(json => $status);
}

sub append {
    my $self = shift;
    my $uri = $self->param('uri');

    if (!$uri) {
        $self->render(json => {error => 'Missing URI'}, code => 400) and return;
    }

    #if ($self->redis->llen('playlist.main') == 0) {
        # Get straight in to it!
    #    $self->redis->set('config.playing', 1);
    #    $self->spot->play(uri => $uri);
    #}

    $self->redis->rpush('playlist.main', $uri);
    my $list = $self->redis->lrange('playlist.main', 0, 100);

    $self->render(json => $list);
}

sub vote_track {
    my $self = shift;
    my $uri = $self->param('uri');

    $self->redis->zincrby('playlist.main', 1, $uri);
    say "[DEBUG] Voted track $uri";

    $self->render(json => {response => 'success'});
}

sub playpause {
    my $self = shift;

    if ($self->tx->remote_address ne '127.0.0.1') {
        $self->render(json => {error => 'Permission denied'}, code => 401) and return;
    }

    my $status;
    eval { $status = decode_json $self->redis->get('state') };
    if ($@) {
        $self->render(json => {error => 'Unable to get state from memory'}, code => 500) and return;
    }

    if ($status->{playing}) {
        $self->redis->set('config.playing', 0);
        $self->spot->pause;
        $self->render(json => {'config.playing' => 0});
    } else {
        $self->redis->set('config.playing', 1);
        $self->spot->play;
        $self->render(json => {'config.playing' => 1});
    }
}

1;
