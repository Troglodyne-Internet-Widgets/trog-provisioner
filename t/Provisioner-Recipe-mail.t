#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-mail.t - what the mail recipe accepts for its relay

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use Provisioner::Cookbook();

my $recipe = Provisioner::Cookbook->load( 'mail', distro => 'ubuntu' )->new(
    template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir    => '/nonexistent',
    distro        => 'ubuntu',
);

my %BASE = (
    domain      => 'mail.test.test',
    install_dir => '/nonexistent',
    admin_user  => 'doge',
);

# transport_maps reads relay.to as a list of destinations.
subtest 'relay.to is a list of destinations' => sub {
    my %none = $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25 } );
    is_deeply( $none{relay}{to}, [], 'no destinations by default' );

    my %some = $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25, to => ['other.test.test'] } );
    is_deeply( $some{relay}{to}, ['other.test.test'], 'the destinations given are kept' );

    like(
        exception { $recipe->validate( %BASE, relay => { host => 'relay.test.test', port => 25, to => 'other.test.test' } ) },
        qr{/relay/to},
        'one destination not in a list is refused'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing();
