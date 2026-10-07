#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-sssd.t - the keys and the sudo that the sssd recipe gives
a user of the directory

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);
my %G = (
    domain      => 'client.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'admin',
    ldap_uri    => 'ldaps://dir.test.test',
    base_dn     => 'dc=dir,dc=test,dc=test',
);

sub recipe {
    return Provisioner::Cookbook->load( 'sssd', distro => 'ubuntu' )->new(%PROV);
}

subtest 'sudo_groups' => sub {
    my $sudoers = recipe()->render_file( 'files/sssd.sudoers.tt', %G, sudo_groups => [qw{github-admins ops}] );
    like( $sudoers, qr/^%github-admins[ ]ALL=\(ALL:ALL\)[ ]NOPASSWD:[ ]ALL$/m, 'a group gets sudo without a password' );
    like( $sudoers, qr/^%ops[ ]/m,                                             'each group' );

    unlike( recipe()->render_file( 'files/sssd.sudoers.tt', %G ), qr/^%/m, 'and none gets none' );

    like( exception { recipe()->validate( %G, sudo_groups => ['ALL, root'] ) }, qr{/sudo_groups/0:}, 'a name that would be more of a sudoers line is refused' );
};

subtest 'keys' => sub {
    my $conf = recipe()->render_file( 'files/sssd.conf.tt', %G );
    like( $conf, qr/^services[ ]=[ ].*\bssh\b/m,                     'sssd answers sshd' );
    like( $conf, qr/^ldap_user_ssh_public_key[ ]=[ ]sshPublicKey$/m, 'from the attribute the ldap recipe writes' );

    like( recipe()->render_file( 'files/sssd.sshd.tt', %G ), qr{^AuthorizedKeysCommand[ ]/usr/bin/sss_ssh_authorizedkeys$}m, 'and sshd asks it' );
};

done_testing();
