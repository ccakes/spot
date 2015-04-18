requires 'EV';
requires 'JSON';
requires 'DBD::SQLite';

requires 'LWP::UserAgent';

eval {
    use LWP;
    requires 'LWP::Protocol::https' if $LWP::VERSION > 6;
};

# Mojolicious and Mojo::Redis
requires 'Mojolicious';
requires 'Mojo::Redis2';
requires 'Mojolicious::Plugin::Web::Auth';
