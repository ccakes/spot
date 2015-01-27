# Spot

Spot and the [web interface](https://github.com/ccakes/spot-webui) is a way for a small group of people to control a single instance of Spotify.

The idea was heavily inspired by [Play](https://github.com/play/play) but for our small office, we didn't need anything quite so elaborate. We already have an AirPlay-driven sound system driven by whoever arrived first in the morning, this just adds a social aspect to that.

I'm also **not** a web developer by any stretch so this was a fun opportunity for me to experiment with some technology that I'd heard about but never really had a chance to play with myself.

## Installation

I'm aiming to include a script to bootstrap the install on linux & OS X but for now, here's something of a step-by-step.
```bash
# If you haven't already, set up Perlbrew and cpanm, go do that now.
# A local Perl environment isn't required but highly recommended

# Install Redis
brew install redis
apt-get install redis-server redis-tools

# Install Carton
cpanm -i Carton

# Install Spotify::Control
cpanm -i git://github.com/ccakes/p5-spotify-control.git

# Install dependencies
carton install

git clone https://github.com/ccakes/spot
cd spot
cp spot.conf.sample spot.conf

# Edit spot.conf to suit environment, defaults should be sane
vim spot.conf

# Run under test server to verify
carton exec morbo script/spot
```

At this stage, you should have Mojolicious listening on tcp/3000 accepting requests. The simplest way to test is to start something playing in Spotify and then browse to http://localhost:3000/v2/state to see the current player status.

Next step is to run under Hypnotoad and to put something like nginx in front of everything. There is a sample nginx config in [examples/](https://github.com/ccakes/spot/tree/master/examples).

## Next Steps

Visit the [web interface](https://github.com/ccakes/spot-webui) repository and install that along side Spot.

## Support

The best way to get support is using the [GitHub issue tracker](https://github.com/ccakes/spot/issues). Please raise an issue for any bugs, feature requests or general questions.

## Contributing

I try to create issues for features that I want to include over time tagged with the enhancement label. Pull Requests are welcome.
