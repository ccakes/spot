package Spot;
use Mojo::Base 'Mojolicious';

use Spotify::Control;

use EV;
use JSON::XS;
use Mojo::Redis2;
use Mojo::UserAgent;

use Time::HiRes qw(usleep);;

use Data::Dumper::Simple;

my $victor = 0;

has redis => sub {
    my $self = shift;

    return Mojo::Redis2->new(url => $self->app->config->{redis_host});
};

has spot => sub {
    return Spotify::Control->new;
};

has ev => sub {
    my $self = shift;

    Mojo::IOLoop->recurring(1, sub {

        # I feel dirty about this.. surely there's a better way
        # Force a battle for superiority, only one can rule!
        #
        # Single thread to handle Spotify, the rest will rely on
        # Redis for state information
        my $master = $self->app->redis->get('config.master');
        if (!$master) {
            usleep(int rand(1000));
            $victor = $self->app->redis->setnx('config.master', $$);
        }

        return unless $victor;

        my $current = $self->app->spot->status;
        my $previous;
        eval { $previous = decode_json $self->app->redis->get('cache.state') };
        if ($@) {
            $self->app->log->error('Unable to get stored state') and return;
        }

        if ($previous->{playing} && !$current->{playing} && $self->app->redis->get('config.playing')) {

            my $new_track;
            if (scalar @{$self->app->redis->zrange('playlist.main', 0, 2)} > 0) {
                $new_track = $self->app->_play_next;
                if (!$new_track) {
                    $self->app->log->error('Error queuing up next track in event loop');
                }

            } else {
                $self->app->log->info("Nothing left to play :[");
                $self->app->redis->set('config.playing', 0);
            }

            # Cache updated in event callback
            # Stop here before we overwrite that with bad data
            return;
        }

        $self->app->redis->set('cache.state', encode_json $current);
    });
};

sub startup {
    my $self = shift;

    $self->plugin('Config', file => sprintf('%s/../spot.conf', $FindBin::Bin));

    if (exists $self->app->config->{auth}) {
        $self->plugin('Web::Auth',
            module => $self->app->config->{auth}->{module},
            key => $self->app->config->{auth}->{key},
            secret => $self->app->config->{auth}->{secret},

            on_finished => sub {
                my $c = shift;
                my $access_token = shift;
                my $account_info = shift;

                my $user = {
                    display_name => $account_info->{displayName},
                    gender => $account_info->{gender},
                    image => $account_info->{image}->{url} || '',
                    oauth_token => $access_token
                };

                # Remember the user for blaming and future trending data
                if (!$self->app->redis->hexists('user.data', $account_info->{id})) {
                    $self->app->redis->hset('user.data', $account_info->{id}, encode_json $user);
                }

                $c->session('spot_user' => $user);

                #return $c->redirect_to('user');
                $c->render(json => $user);
            }
        );
    }

    # preseed some values
    my $state = $self->app->spot->status;
    $self->app->redis->set('cache.state', encode_json $state);
    #$self->app->redis->set('config.playing', $state->{playing});
    if (!$self->app->redis->get('config.score')) {
        $self->app->redis->set('config.score', 1000);
    }

    $self->app->redis->del('config.master');
    $self->app->ev;

    my $r = $self->routes->bridge('/v2')->to(controller => 'v2', action => 'auth');

    $r->get('/status')->to(controller => 'v2', action => 'status');

    $r->get('/state')->to(controller => 'v2', action => 'state');
    $r->get('/playlist')->to(controller => 'v2', action => 'playlist');
    $r->get('/append/:uri')->to(controller => 'v2', action => 'append');
    $r->get('/vote/:uri')->to(controller => 'v2', action => 'vote');

    $r->get('/playpause')->to(controller => 'v2', action => 'playpause');
    $r->get('/start')->to(controller => 'v2', action => 'start');

    $r->get('/user/:uid')->to(controller => 'v2', action => 'user', uid => undef);

    $r->websocket('/sock')->to(controller => 'v2', action => 'sock');

    $r->get('/account' => sub {
        my $self = shift;

        my $account_info = {stored => {}, session => $self->session};
        if ($self->session('account_info')) {
            eval { $account_info->{stored} = decode_json $self->app->redis->hget('user.data', $self->session('account_info')->{id}) };
        }

        $self->render(json => $account_info);
    });

    $r->get('/logout' => sub {
        my $self = shift;

        $self->session(expires => 1);
        $self->render(text => 'Logged out');
    });
}

sub _play_next {
    my $self = shift;

    if (!$self->app->redis->get('config.playing')) {
        return;
    }

    # Fetch track play it and incr counters
    my $next = $self->app->redis->zrange('playlist.main', 0, 1)->[0];
    return unless $next;

    $self->app->spot->play(uri => $next);

    my $user_id = $self->app->redis->hget('playlist.user_map', $next);

    my $user;
    if ($user_id) {
        eval { $user = decode_json $self->app->redis->hget('user.data', $user_id) };
    }

    $self->app->log->info( sprintf('Playing track: %s', $next) );

    $self->app->redis->set('cache.current_track', encode_json {track => $next, user => $user});
    $self->app->redis->hincrbyfloat('cache.played', $next, 1.0);

    # Clean up
    $self->app->redis->zrem('playlist.main', $next);

    my $new_state = $self->app->spot->status;
    $self->app->redis->set('cache.state', encode_json $new_state);

    # Send an event to clients to update playlists
    $self->app->redis->publish('spot.events', 'update_playlist');
    $self->app->redis->publish('spot.events', 'update_track');

    return $next;
}

# Add track to playlist
sub _queue_track {
    my $self = shift;
    my $uri = shift;

    # Check for a cache hit to avoid hitting Spotify
    my $cache = $self->app->redis->hget('cache.tracks', $uri);
    if (!$cache) {

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
        my $insert = {
            artist => $track->{artists}->[0]->{name},
            track => $track->{name},
            album => {
                name => $track->{album}->{name},
                uri => $track->{album}->{uri},
                cover => $track->{album}->{images}->[0]->{url} || ''
            }
        };

        $self->app->redis->hset('cache.tracks', $uri, encode_json $insert);
        $cache = $self->app->redis->hget('cache.tracks', $uri);
    }

    my $track;
    eval { $track = decode_json $cache };
    if ($@) {
        say "[ERR] Error querying Redis for track $uri" and return;
    }

    $self->app->log->info( sprintf('Queuing track: %s - %s', $track->{artist}, $track->{track}) );

    # Grab the next score then add the track
    # Try this out as an alternative to keying the records
    my $score = $self->app->redis->incr('config.score');
    $self->app->redis->zadd('playlist.main', $score, $uri);

    # Send an event to clients to update playlists
    $self->app->redis->publish('spot.events', 'update_playlist');

    return 1;
}

1;
