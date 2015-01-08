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

    $self->tx->res->headers->header('Access-Control-Allow-Origin' => '*');

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
        }
    };

    $self->render(json => $response);
}

sub playlist {
    my $self = shift;

    my $playlist = [];
    my $zset = $self->app->redis->zrange('playlist.main', 0, 100);

    foreach (@$zset) {
        my $track_data = $self->app->redis->hget('cache.tracks', $_);

        if (!$track_data) {
            $self->app->log->error("Unable to lookup track data for $_");
            next;
        }

        my $track;
        eval { $track = decode_json $track_data };
        if ($@) {
            $self->app->log->error("Corrupted data in Redis for track $_");
            next;
        }
        $track->{uri} = $_;

        push @$playlist, $track;
    }

    $self->render(json => $playlist);
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

    #my $loop = Mojo::IOLoop->singleton;
    #$loop->stream($self->tx->connection)->timeout(60);
    $self->inactivity_timeout(300);

    if (exists $self->app->config->{auth} && $self->session('account_info')) {
        my $account = $self->session('account_info');

        # Manage "current listeners" via websocket connections
        $self->app->redis->rpush('cache.users', $account->{id});
        $self->app->state->user($account->{id}, 1);

        $self->on(finish => sub {
            $self->app->redis->lrem('cache.users', 0, $account->{id});
            $self->app->state->user($account->{id});
        });
    }

    # drop inbound messages
    $self->on(message => sub {
        my ($c, $data) = @_;

        my $msg;
        eval { $msg = decode_json $data };
        return if $@;

        $c->send({json => {type => 'pong'}}) if $msg->{type} eq 'ping';
    });

    $self->app->state->on(track_change => sub {
        $self->send({json => {type => 'update', item => 'track'}});
    });

    $self->app->state->on(playlist_update => sub {
        $self->send({json => {type => 'update', item => 'playlist'}});
    });

    $self->app->state->on(user_joined => sub {
        $self->send({json => {type => 'update', item => 'users'}});
    });

    $self->app->state->on(user_left => sub {
        $self->send({json => {type => 'update', item => 'users'}});
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

        my $track_id = (split /\:/, $uri)[2];

        # Fetch track info and add asynchronously
        my $ua = Mojo::UserAgent->new;
        my $tx = $ua->get('https://api.spotify.com/v1/tracks/' . $track_id);

        if ($tx->error) {
            # TODO
            # throw error on redis queue
            say Dumper($tx);
            say "[ERR] Spotify return error for $uri" and return;
        }

        my $track = decode_json $tx->res->body;
        my $cache = {
            artist => $track->{artists}->[0]->{name},
            track => $track->{name},
            album => {
                name => $track->{album}->{name},
                uri => $track->{album}->{uri},
                cover => $track->{album}->{images}->[0]->{url} || ''
            }
        };

        if (exists $self->app->config->{auth} && $self->session('account_info')) {
            $cache->{user} = {id => $self->session('account_info')->{id}, display => $self->session('account_info')->{displayName}};
        }

        $self->app->redis->hset('cache.tracks', $uri, encode_json $cache);

        $self->app->_queue_track($uri);

        $self->render(json => {ueued => $uri}) and return;
    }
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

sub playpause {
    my $self = shift;

    my $status;
    eval { $status = decode_json $self->app->redis->get('cache.state') };
    if ($@) {
        $self->render(json => {error => 'Unable to get state from memory'}, code => 500) and return;
    }

    if ($status->{playing}) {
        $self->app->log->info("Pausing player");
        $self->app->redis->set('config.playing', 0);
        $self->app->spot->pause;
        $self->render(json => {'config.playing' => 0});
    } else {
        $self->app->log->info("Starting player");

        if ($status->{track}->{track_resource}->{uri}) {
            $self->app->redis->set('config.playing', 1);
            $self->app->spot->unpause;
        } else {
            $self->app->redis->set('config.playing', 1);
            my $next_track = $self->app->_play_next;
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
    eval { $status = decode_json $self->app->redis->get('cache.state') };
    if ($@) {
        $self->render(json => {error => 'Unable to get state from memory'}, code => 500) and return;
    }

    $self->app->redis->set('config.playing', 1);
    my $next_track = $self->app->_play_next;
    $self->render(json => {current_track => $next_track});
}

1;
