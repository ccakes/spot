package Spot::V2;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::UserAgent;
use JSON::XS;

use Data::Dumper::Simple;

# Bridge for handling authentication
sub auth {
    my $self = shift;

    # Grab the final action from the stack
    my $action = $self->match->{stack}->[-1]->{action};

    if (exists $self->app->config->{auth} && grep /^$action$/, @{$self->app->config->{auth}->{actions}}) {
        if (!$self->session('account_info')) {
            return $self->redirect_to( sprintf('/auth/%s/authenticate', lc $self->app->config->{auth}->{module}) );
        }
    }

    return 1;
}

sub state {
    my $self = shift;

    my $state;
    eval { $state = decode_json $self->app->redis->get('cache.state') };
    if ($@) {
        $self->app->log->error('Unable to get stored state - ' . $@);
        $self->render(json => {error => 'Unable to get state from Redis'}, code => 500) and return;
    }

    my $playlist = $self->app->redis->zrange('playlist.main', 0, 100);

    my $response = {
        client_version => $state->{client_version},
        playing => $state->{playing},
        currently_playing => {
            artist => {
                name => $state->{track}->{artist_resource}->{name},
                uri => $state->{track}->{artist_resource}->{uri}
            },
            track => {
                name => $state->{track}->{track_resource}->{name},
                uri => $state->{track}->{track_resource}->{uri}
            },
            album => {
                name => $state->{track}->{album_resource}->{name},
                uri => $state->{track}->{album_resource}->{uri}
            }
        },
        playlist => $playlist
    };

    $self->render(json => $response);
}

sub status {
    my $self = shift;

    my $state;
    eval { $state = decode_json $self->app->redis->get('cache.state') };
    if ($@) {
        $self->app->log->error('Unable to get stored state - ' . $@);
        $self->render(json => {error => 'Unable to get state from Redis'}, code => 500) and return;
    }

    $self->render(json => $state);
}

sub sock {
    my $self = shift;

    my $loop = Mojo::IOLoop->singleton;
    $loop->stream($self->tx->connection)->timeout(1000);

    # Manage "current listeners" via websocket connections

    # drop inbound messages
    $self->on(message => sub {});

    $self->app->state->on(update => sub {
        $self->send(json => {action => '/state'});
    });
}

sub append {
    my $self = shift;
    my $uri = $self->param('uri');

    if (!$uri) {
        $self->render(json => {error => 'Missing URI'}, code => 400) and return;
    }

    # Check for duplicates
    if ($self->app->redis->zscore('playlist.main', $uri)) {
        $self->render(json => {error => 'Track exists in playlist'}) and return;
    }

    # Check for a cache hit to avoid hitting Spotify
    my $cache = $self->app->redis->hget('cache.tracks', $uri);
    if ($cache) {

        $self->app->_queue_track($uri);
        $self->render(json => {track => 'queued'}) and return;

    } else {

        # Fetch track info and add asynchronously
        my $ua = Mojo::UserAgent->new;
        $ua->get('https://api.spotify.com/v1/tracks/' . $uri => {Accept => 'application/json'} => sub {
            my ($ua, $tx) = @_;

            if ($tx->res->code != 200) {
                # TODO
                # throw error on redis queue
                say "[ERR] Spotify return error for $uri" and return;
            }

            my $track = decode_json $tx->res->body;
            $self->app->redis->hadd('cache.tracks', $uri, encode_json {
                artist => $track->{artists}->[0]->{name},
                track => $track->{name},
                album => {
                    name => $track->{album}->{name},
                    uri => $track->{album}->{uri},
                    cover => $track->{album}->{images}->[0]->{url} || ''
                }
            });

            $self->app->_queue_track($uri);
        });

    }

    $self->render(json => {track => 'pending'});
}

sub vote {
    my $self = shift;
    my $uri = $self->param('uri');

    if (!$uri) {
        $self->render(json => {error => 'Missing URI'}, code => 400) and return;
    }

    if (!$self->app->redis->zscore('playlist.main', $uri)) {
        $self->render(json => {error => 'Given track not in current playlist'}, code => 400) and return;
    }

    my $score = $self->app->redis->zincrby('playlist.main', -10, $uri);
    $self->app->log->info("Voted track $uri");

    $self->render(json => {track => $score});
}

1;
