requires 'EV';
requires 'JSON';

requires 'LWP::UserAgent';

eval {
    use LWP;
    requires 'LWP::Protocol::https' if $LWP::VERSION > 6;
}

# Mojolicious and Mojo::Redis
requires 'Mojolicious', '5.70';
requires 'Mojo::Redis2';

# Spotify controller - this is just to validate it was installed previously
# Install via cpanm (cpanm -i git://github.com/ccakes/p5-spotify-control.git)
requires 'Spotify::Control';
