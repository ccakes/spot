package SpotifyLocal::Local;

use 5.10.0;
use strict;
use warnings FATAL => 'all';

use Carp;
use JSON::XS;
use URI;
use LWP::UserAgent;

use Data::Dumper::Simple;

=head1 NAME

Spotify::Local - The great new Spotify::Local!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Spotify::Local;

    my $spotify = Spotify::Local->new;
    $spotify->pause; # pause current track
    $spotify->play; # play current track

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 SUBROUTINES/METHODS

=head2 new

=cut

sub new {
    my $self = bless {}, shift;
    return unless @_ % 2 == 0;

    my %args = @_;

    my %defaults = (
        _ua => LWP::UserAgent->new(agent => __PACKAGE__ . '/' . $VERSION, ssl_opts => { verify_hostname => 0 }),
        _oauth => undef,
        _csrf => undef,

        hostname => join('', map(sprintf("%x", rand 16), 1..8)) . '.spotilocal.com',
        port => 4370,

        headers => ['Origin', 'https://open.spotify.com'],
    );

    foreach (keys %defaults) {
        $self->{$_} = exists $args{$_} ? $args{$_} : $defaults{$_};
    }

    return $self;
}

=head2 initialise

Grab OAuth and CSRF tokens to use in subsequent requests

    $spotify->initialise

=cut

sub initialise {
    my $self = shift;

    $self->{_oauth} = decode_json($self->ua->get('http://open.spotify.com/token')->content)->{t};
    $self->{_csrf} = decode_json($self->ua->get(sprintf('https://%s:%d', $self->{hostname}, $self->{port}) . '/simplecsrf/token.json', @{$self->{headers}})->content)->{token};

    return 1 unless ($self->{_oauth} && $self->{_csrf});
}

=head2 ua

Get or set UserAgent object

    say ref($spotify->ua);
    my $ua = my $lwp = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0 } );
    $ua->proxy('https', 'http://127.0.0.1:8080');
    $spotify->ua($ua);

=cut

sub ua {
    ( ref $_[1] ) ? shift->{_ua} = $_[1] : shift->{_ua};
}

# test track: spotify:track:5pjv4zDJwSJUYWRldSoOXe
sub play {
    my $self = shift;
    return unless @_ % 2 == 0;
    my %args = @_;

    return unless exists $args{uri};
    $args{context} = $args{uri} unless exists $args{context}; # add context if not set

    return $self->_request('/remote/play.json', %args);
}

sub pause {
    return decode_json(shift->_request('/remote/pause.json', pause => 'true')->content);
}

sub unpause {
    return decode_json(shift->_request('/remote/pause.json', pause => 'false')->content);
}

sub status {
    return decode_json(shift->_request('/remote/status.json', returnafter => 1)->content);
}

=head2 _request

Build HTTP request

=cut

sub _request {
    my $self = shift;
    my $uri = shift;
    return unless @_ % 2 == 0;

    my %args = @_;

    my $params = {
        oauth => $self->{_oauth},
        csrf => $self->{_csrf}
    };
    map { $params->{$_} = $args{$_} } keys %args;

    my $url = URI->new(sprintf('https://%s:%d%s', $self->{hostname}, $self->{port}, $uri));
    $url->query_form($params);

    my $response = $self->ua->get($url->as_string, @{$self->{headers}});

    return $response;
}

=head1 AUTHOR

Cameron Daniel, C<< <cdaniel at nurve.com.au> >>

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Spotify::Local

=cut

1;
