package SpotifyLocal::Controller::Main;

use Mojo::Base 'Mojolicious::Controller';

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

    $status->{playlist} = $self->playlist;

    $self->render(json => $status);
}

sub append {
    my $self = shift;
    my $uri = $self->param('uri');

    if (!$uri) {
        $self->render(json => {error => 'Missing URI'}, code => 400) and return;
    }

    if (scalar @{$self->playlist} == 0) {
        # Get straight in to it!
        $self->spot->play(uri => $uri);
    }

    push(@{$self->playlist}, $uri);
    my $list = $self->playlist;

    say Dumper($list);

    $self->render(json => $list);
}

1;
