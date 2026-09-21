#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-plexmediaserver.t - the claim token that links a new server

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};

use FindBin::libs;

use Provisioner::Cookbook();

# A new one each time: a recipe object validates its configuration once.
sub recipe {
    return Provisioner::Cookbook->load( 'plexmediaserver', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => '/nonexistent',
        distro        => 'ubuntu',
    );
}

my %BASE = (
    domain          => 'plex.test.test',
    install_dir     => '/opt/domains',
    admin_user      => 'someadmin',
    script_dir      => '/root/bin',
    main_ip         => '192.0.2.9',
    plex_login_name => 'plexuser',
    admin_mail      => 'admin@test.test',
);

subtest 'claim_token' => sub {
    my $out = recipe()->render( %BASE, claim_token => 'claim-AbC123_x-y' );
    like( $out, qr/'PLEX_CLAIM=claim-AbC123_x-y'/, 'is written to /etc/default/plexmediaserver' ) or diag $out;

    unlike( recipe()->render(%BASE), qr/PLEX_CLAIM/, 'and nothing is written without one' );

    like( exception { recipe()->validate( %BASE, claim_token => q{claim-x'; rm -rf /bogus; '} ) }, qr{/claim_token}, 'a token that is not one is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
