package SpotifyLocal;

use Mojo::Base 'Mojolicious';

use Spotify::Control;
use Spotify::Control::HTTP;

use JSON;
use Redis;
use LWP::UserAgent;

use Data::Dumper::Simple;

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->plugin('Config', file => sprintf('%s/../spotify.conf', $FindBin::Bin));

    # method => invalid is so I can set up the UA. This is to work around an SSL issue on my local machine
    $self->attr('spotify', sub { Spotify::Control->new(method => 'invalid') });
    $self->helper('spot', sub { return shift->app->spotify });

    my $ua = LWP::UserAgent->new(ssl_opts => {verify_hostname => 0});
    my $spot_http = Spotify::Control::HTTP->new;
    $spot_http->ua($ua);
    $self->spot->spot($spot_http);
    $self->spot->spot->initialise;

    $self->attr('redis', sub { Redis->new(server => 'localhost:6379') });
    $self->helper('redis', sub { return shift->app->redis });

    # preseed
    my $status = $self->spot->status;
    $self->redis->set('state', encode_json $status);
    $self->redis->set('config.playing', $status->{playing});

    # Router
    my $r = $self->routes;

    $r->get('/')->to(controller => 'main', action => 'main');
    $r->get('/status')->to(controller => 'main', action => 'status');
    $r->get('/append/:uri')->to(controller => 'main', action => 'append');
    $r->get('/vote/:uri')->to(controller => 'main', action => 'vote_track');
    $r->get('/playpause')->to(controller => 'main', action => 'playpause');
    $r->get('/start')->to(controller => 'main', action => 'start');
    $r->get('/export')->to(controller => 'main', action => 'export');

    $r->post('/import')->to(controller => 'main', action => 'import');

    sub compare_hash {
        my $j = JSON::XS->new->canonical(1)->pretty(1);

        # These fields always change - don't compare them
        delete $_[0]->{playing_position};
        delete $_[1]->{playing_position};
        delete $_[0]->{server_time};
        delete $_[1]->{server_time};

        #if ($j->encode($_[0]) ne $j->encode($_[1])) {
        #    say "\n------------ CURRENT ------------";
        #    say $j->encode($_[0]);
        #    say "------------ EXISTING ------------";
        #    say $j->encode($_[1]);
        #    say '-' x 20;
        #}

        $j->encode(shift) eq $j->encode(shift);
    }

    Mojo::IOLoop->recurring(1 => sub {

        my $current = $self->spot->status;
        my $state;
        eval { $state = decode_json $self->redis->get('state') };
        if ($@) {
            $self->app->log->error("Unable to get stored status") and return;
        }

        if (!compare_hash($current, $state)) {
            $self->app->log->info("State change!");
            #say Dumper($playlist);

            #if ($self->state->{playing} && ($state->{track}->{track_resource}->{uri} != $current->{track}->{track_resource}->{uri})) {
            if ($state->{playing} && !$current->{playing} && $self->redis->get('config.playing')) {
                # New track.. do we have another to play?
                my $playlist = $self->redis->zrange('playlist.main', 0, 100);

                if (scalar @$playlist > 0) {
                    my $next_track = $self->redis->zrange('playlist.main', 0, 1)->[0];

                    # Clean up
                    $self->redis->zrem('playlist.main', $next_track);
                    $next_track = (split /\|/, $next_track)[1];
                    $self->redis->hdel('playlist.main.lookup', $next_track);

                    $self->app->log->info("$$: IOLoop - playing $next_track");
                    $self->spot->play(uri => $next_track);
                    $self->redis->set('current_track', $next_track);
                } else {
                    $self->app->log->info("Nothing else to play :(");
                }
            }

            $self->redis->set('state', encode_json $current);
        }
    });
}

1;
