package SpotifyLocal::Controller::Main;

use Mojo::Base 'Mojolicious::Controller';

use JSON;
use Time::Piece;

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
    my $zset = $self->redis->zrange('playlist.main', 0, 100);
    #say Dumper($status);

    # Strip ordering key
    my @playlist = map { (split /\|/, $_)[1] } @$zset;

    $status->{playlist} = \@playlist;

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

    # Key the ZSET for lexical ordering on query
    # Then store the key in a lookup table so we can use it later
    my $key = $self->redis->incr('config.incr');
    $self->redis->zadd('playlist.main', 10, $key . '|' . $uri);
    $self->redis->hset('playlist.main.lookup', $uri, $key);

    $self->render(json => {response => 'success'});
}

sub vote_track {
    my $self = shift;
    my $uri = $self->param('uri');

    my $key = $self->redis->hget('playlist.main.lookup', $uri);
    if (!$key) {
        $self->render(json => {errors => 'Lookup for track failed'}) and return;
    }

    $self->redis->zincrby('playlist.main', -1, $key . '|' . $uri);
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
        say "[DEBUG] Pausing player";
        $self->redis->set('config.playing', 0);
        $self->spot->pause;
        $self->render(json => {'config.playing' => 0});
    } else {
        say "[DEBUG] Starting player";

        if ($status->{track}->{track_resource}->{uri}) {
            $self->redis->set('config.playing', 1);
            $self->spot->unpause;
        } else {
            my $next_track = $self->redis->zrange('playlist.main', 0, 1)->[0];

            # Clean up
            $self->redis->zrem('playlist.main', $next_track);
            $next_track = (split /\|/, $next_track)[1];
            $self->redis->hdel('playlist.main.lookup', $next_track);

            say "[DEBUG] Playing $next_track";
            $self->redis->set('config.playing', 1);
            $self->spot->play(uri => $next_track);
            $self->redis->set('current_track', $next_track);
        }

        $self->render(json => {'config.playing' => 1});
    }
}

sub start {
    my $self = shift;

    if ($self->tx->remote_address ne '127.0.0.1') {
        $self->render(json => {error => 'Permission denied'}, code => 401) and return;
    }

    my $status;
    eval { $status = decode_json $self->redis->get('state') };
    if ($@) {
        $self->render(json => {error => 'Unable to get state from memory'}, code => 500) and return;
    }

    if ($status->{playing} && ($self->redis->get('current_track') ne $status->{track}->{track_resource}->{uri})) {
        $self->spot->pause;
    }

    my $next_track = $self->redis->zrange('playlist.main', 0, 1)->[0];

    # Clean up
    $self->redis->zrem('playlist.main', $next_track);
    $next_track = (split /\|/, $next_track)[1];
    $self->redis->hdel('playlist.main.lookup', $next_track);

    say "[DEBUG] Playing $next_track";
    $self->redis->set('config.playing', 1);
    $self->spot->play(uri => $next_track);
    $self->redis->set('current_track', $next_track);

    $self->render(json => {current_track => $next_track});
}

1;
