#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/openstack-useragent.t - Trog::OpenStack::UserAgent: the certificate does get
checked

=cut

use Test::More;

use FindBin::libs;

use OpenStack::Client();
use Trog::OpenStack::UserAgent();

subtest 'it is a user agent' => sub {
    my $ua = Trog::OpenStack::UserAgent->new();

    isa_ok $ua, 'LWP::UserAgent';
    is $ua->ssl_opts('verify_hostname'), 1, 'verifying by default';
    is $ua->ssl_opts('SSL_verify_mode'), 1, 'and with a verify mode set';
};

subtest 'asking for no verification does not get you any' => sub {
    my $ua = Trog::OpenStack::UserAgent->new( ssl_opts => { verify_hostname => 0, SSL_verify_mode => 0 } );

    is $ua->ssl_opts('verify_hostname'), 1, 'overridden rather than defaulted';
    is $ua->ssl_opts('SSL_verify_mode'), 1, 'both of them';
};

subtest 'the rest of ssl_opts is left alone' => sub {
    my $ua = Trog::OpenStack::UserAgent->new( ssl_opts => { SSL_ca_file => '/somewhere/ca.pem' } );

    is $ua->ssl_opts('SSL_ca_file'),     '/somewhere/ca.pem', 'a CA bundle survives';
    is $ua->ssl_opts('verify_hostname'), 1,                   'alongside the verification';
};

subtest 'which is the whole point: OpenStack::Client cannot turn it off' => sub {

    # OpenStack::Client->new hardcodes ssl_opts => { verify_hostname => 0 } and
    # takes the agent as a class name.  This is the assertion that naming this
    # class actually defeats that, rather than merely looking like it should.
    my $client = OpenStack::Client->new(
        'https://keystone.example.net:5000/v3',
        package_ua => 'Trog::OpenStack::UserAgent',
    );

    isa_ok $client->{ua}, 'Trog::OpenStack::UserAgent';
    is $client->{ua}->ssl_opts('verify_hostname'), 1,
      'the token will not be handed to whatever answered the connection';

    # And what it looks like when nobody says otherwise, so this test fails if
    # OpenStack::Client ever stops doing it and the override becomes dead code.
    my $default = OpenStack::Client->new('https://keystone.example.net:5000/v3');
    is $default->{ua}->ssl_opts('verify_hostname'), 0,
      'which is still worth doing, because the default is not to';
};

done_testing();
