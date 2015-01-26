package Spot::V2;
use Mojo::Base 'Mojolicious::Controller';

use JSON;

# Bridge for handling authentication
sub auth {
    my $self = shift;

    # TODO
    # Remove bridge route if safe to do so
    return 1;

    # Grab the final action from the stack
    my $action = $self->match->{stack}->[-1]->{action};

    $self->tx->res->headers->header('Access-Control-Allow-Origin' => '*');

    if (exists $self->app->config->{auth} && grep /^$action$/, @{$self->app->config->{auth}->{actions}}) {
        if (!$self->session('spot_user')) {
            return $self->redirect_to( sprintf('/auth/%s/authenticate', lc $self->app->config->{auth}->{module}) );
        }
    }

    return 1;
}

sub user {
    my $self = shift;

    if (exists $self->app->config->{auth} && $self->app->config->{auth}->{enabled}) {

        my $spot_uid = $self->param('uid');
        my $user;

        # Nothing - redirect to auth provider
        if (!$self->session('spot_user') && !$spot_uid) {
            return $self->redirect_to( sprintf('/auth/%s/authenticate', lc $self->app->config->{auth}->{module}) );
        }
        # Saved session, lets grab the details from Redis
        elsif (!$self->session('spot_user')) {
            if ($self->app->redis->hexists('user.data', $spot_uid)) {
                eval { $user = decode_json $self->app->redis->hget('user.data', $spot_uid) };

                $self->app->redis->hdel('user.data', $spot_uid) if $@; # Delete entry if not valid JSON
            }

            # If either the user doesn't exist in Redis or the data is corrupted, start again
            if (!$user) {
                return $self->redirect_to( sprintf('/auth/%s/authenticate', lc $self->app->config->{auth}->{module}) );
            }

            $self->session('spot_user', $user);
        }
        # Valid session
        else {
            $user = $self->session('spot_user');
        }

        $self->render(json => $self->session('spot_user')) and return;
    }

    $self->render(text => '', code => 204);
}

sub state {
    my $self = shift;

    my $state;
    eval { $state = decode_json $self->app->redis->get('cache.state') };
    if ($@) {
        $self->app->log->error('Unable to get stored state - ' . $@);
        $self->render(json => {error => 'Unable to get state from Redis'}, code => 500) and return;
    }

    my $cache;
    eval { $cache = decode_json $self->app->redis->hget('cache.tracks', $state->{track}->{track_resource}->{uri}) };

    my $user;
    eval { $user = decode_json($self->app->redis->get('cache.current_track'))->{user} };

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
                uri => $state->{track}->{album_resource}->{uri},
                cover => $cache->{album}->{cover} || ''
            },
            user => $user
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

        # Add user if auth
        if (exists $self->app->config->{auth}) {
            my $id = $self->app->redis->hget('playlist.user_map', $_);
            if ($id) {
                my $user;
                eval { $user = decode_json $self->app->redis->hget('user.data', $id) };

                $track->{user} = $user;
            }
        }

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

    $self->inactivity_timeout(300);

    #if (exists $self->app->config->{auth} && $self->session('account_info')) {
    if (0) {
        my $account = $self->session('spot_user');

        # Manage "current listeners" via websocket connections
        $self->app->redis->rpush('cache.users', $account->{id});
        $self->app->state->user($account->{id}, 1);

        $self->on(finish => sub {
            $self->app->redis->lrem('cache.users', 0, $account->{id});
            $self->app->state->user($account->{id});
        });
    }

    my $sub = $self->app->redis->subscribe(['spot.events']);

    my $cb = $sub->on(message => sub {
        my ($redis, $data, $topic) = @_;

        if ($data eq 'update_playlist') {
            $self->send({json => {type => 'update', item => 'playlist'}});
        }
        elsif ($data eq 'update_track') {
            $self->send({json => {type => 'update', item => 'track'}});
        }
    });

    # ping pong
    $self->on(message => sub {
        my ($c, $data) = @_;

        my $msg;
        eval { $msg = decode_json $data };
        return if $@;

        $c->send({json => {type => 'pong'}}) if $msg->{type} eq 'ping';
    });

    $self->on(finish => sub {
        my $self = shift;

        $self->app->redis->unsubscribe(message => $cb);
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

    if ($self->app->_queue_track($uri) && $self->session('spot_user')) {
        my $account_info = $self->session('spot_user');
        $self->app->redis->hset('playlist.user_map', $uri, $account_info->{id});
    }

    $self->render(json => {queued => $uri}) and return;
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

    # TODO
    # This check doesn't need to be here
    # Maybe go back to hijacking the player, regardless of state, when a track is queued?
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
