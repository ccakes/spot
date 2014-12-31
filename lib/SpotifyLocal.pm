package SpotifyLocal;

use Mojo::Base 'Mojolicious';

use Test::Deep::NoTest;
use SpotifyLocal::Local;

use Data::Dumper::Simple;

my $playlist = [];
my $state = {};

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->attr('spotify', sub { SpotifyLocal::Local->new });
    $self->helper('spot', sub { return shift->app->spotify });
    $self->spot->initialise;

    $self->attr('playlist', sub { $playlist });
    $self->helper('playlist', sub { return shift->app->playlist });

    $self->attr('state', sub { $state });
    $self->helper('state', sub { return shift->app->state });

    # Router
    my $r = $self->routes;

    $r->get('/')->to(controller => 'main', action => 'main');
    $r->get('/status')->to(controller => 'main', action => 'status');
    $r->get('/append/:uri')->to(controller => 'main', action => 'append');

    sub compare_hash {
        my $j = JSON::XS->new->canonical(1)->pretty(1);

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

        print ".";

        my $current = $self->spot->status;
        if (!compare_hash($current, $state)) {
            say "\n[DEBUG] State change!";
            say Dumper($playlist);

            #if ($self->state->{playing} && ($state->{track}->{track_resource}->{uri} != $current->{track}->{track_resource}->{uri})) {
            if ($state->{playing} && !$current->{playing}) {
                # New track.. do we have another to play?
                if (scalar @$playlist > 0) {
                    shift @{$self->playlist};
                    my $next_track = $playlist->[0];
                    say "[DEBUG] Playing $next_track";
                    $self->spot->play(uri => $next_track);
                } else {
                    say "[DEBUG] Nothing else to play :(";
                }
            }

            $state = $current;

        }
    });
}

1;
