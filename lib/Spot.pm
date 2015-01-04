package Spot;
use Mojo::Base 'Mojolicious';

use Spotify::Control;

use EV;
use Redis;
use JSON::XS;

use Time::HiRes qw(usleep);

use Spot::EventEmitter::State;

use Data::Dumper::Simple;

my $victor = 0;

has redis => sub {
    my $self = shift;

    return Redis->new(server => $self->app->config->{redis_host});
};

has spot => sub {
    return Spotify::Control->new;
};

has state => sub {
    return Spot::EventEmitter::State->new;
};

has ev => sub {
    my $self = shift;

    Mojo::IOLoop->recurring(2, sub {

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

            if (scalar @{$self->app->redis->zrange('playlist.main', 0, 100)} > 0) {
                if (!$self->app->_play_next) {
                    $self->app->log->error('Error queuing up next track in event loop');
                }
            } else {
                $self->app->log->info("Nothing left to play :[");
            }

            $self->app->redis->set('cache.state', encode_json $current);

            # TODO
            # Expand this to emit specific events for play, pause, track_change, volume etc
            # Then allow plugins/extensions to register interest in events
            $self->app->state->update(1);
        }
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

                $c->session('access_token' => $access_token);
                $c->session('account_info' => $account_info);

                return $c->redirect_to('account');
            }
        );
    }

    # preseed some values
    my $state = $self->app->spot->status;
    $self->app->redis->set('cache.state', encode_json $state);
    $self->app->redis->set('config.playing', $state->{playing});
    if (!$self->app->redis->get('config.score')) {
        $self->app->redis->set('config.score', 1000);
    }

    $self->app->redis->del('config.master');
    $self->app->ev;

    my $r = $self->routes->bridge('/v2')->to(controller => 'v2', action => 'auth');

    $r->get('/state')->to(controller => 'v2', action => 'state');
    $r->get('/status')->to(controller => 'v2', action => 'status');
    $r->get('/append/:uri')->to(controller => 'v2', action => 'append');
    $r->get('/vote/:uri')->to(controller => 'v2', action => 'vote');

    $r->websocket('/sock')->to(controller => 'v2', action => 'sock');

    $r->get('/account' => sub {
        my $self = shift;

        my $j = JSON::XS->new->allow_blessed(1);
        my $obj = $j->decode($j->encode($self));
        $self->render(json => $obj);
    });
}

sub _play_next {
    my $self = shift;

    if (!$self->app->redis->get('config.playing')) {
        return;
    }

    # Fetch track play it and incr counters
    my $next = $self->app->redis->zrange('playlist.main', 0, 1)->[0];

    $self->app->spot->play(uri => $next);

    $self->app->redis->set('cache.current_track', $next);
    $self->app->redis->hincrbyfloat('cache.played', $next, 1.0);

    # Clean up
    $self->app->redis->zrem('playlist.main', $next);

    return 1;
}

# Add track to playlist
sub _queue_track {
    my $self = shift;
    my $uri = shift;

    # Check that we already know about this track
    my $cache = $self->app->redis->hget('cache.tracks', $uri);
    # return unless $cache;
    if (!$cache) {
        say "[ERR] $uri passed to _queue_track but missing from cache" and return;
    }

    $self->app->log->info( sprintf('Queuing track: %s - %s', $cache->{artist}, $cache->{track}) );

    # Grab the next score then add the track
    # Try this out as an alternative to keying the records
    my $score = $self->app->redis->incr('config.score');
    $self->app->redis->zadd('playlist.main', $score, $uri);

    return 1;
}

1;
