#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('Spot');
$t->ua->max_redirects(1);

# is server running & responding?
$t->get_ok('/version')
    ->status_is(200)
    ->content_type_is('application/json');

done_testing;
