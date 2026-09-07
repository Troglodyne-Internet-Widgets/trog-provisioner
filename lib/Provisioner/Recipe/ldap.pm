package Provisioner::Recipe::ldap;

#ABSTRACT: Install and configure OpenLDAP as a domain identity server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ldap

=head2 SYNOPSIS

    somedomain:
        ldap:
            admin_password: s3cr3t

Or with explicit base DN and LDAPS port:

    somedomain:
        ldap:
            admin_password: s3cr3t
            base_dn: dc=example,dc=com
            port: 636

=head2 DESCRIPTION

Installs and configures OpenLDAP (slapd) as a domain identity server.

Users from C<users.yaml> are seeded as POSIX accounts with the C<inetOrgPerson>,
C<posixAccount>, and C<shadowAccount> object classes, plus C<ldapPublicKey> for
SSH public key storage.

LDAPS is configured using the certificate provided by the C<letsencrypt> recipe.
Port 389 (plain LDAP) is left open for local connections only; port 636 (LDAPS)
is exposed for remote authentication (e.g. SSSD clients).

Requires the C<letsencrypt> recipe for TLS certificates.

=head2 SURVIVING A REBUILD

The seed is what a directory starts as, not what it is.  Every password a user
has changed since, every SSH key they have added, every group an operator made
by hand, lives in C</var/lib/ldap> and in nothing else -- so a guest rebuilt
from the recipe alone comes up with its users as they were on the day it was
first provisioned, and nobody finds out until somebody cannot log in.

C</var/lib/ldap> cannot simply be salvaged, and neither can C</etc/ldap/slapd.d>.
The fetch is sftp as the admin user with no sudo, and the package ships both of
those 0700 C<openldap:openldap>: named here, either comes back as an empty
directory and nothing anywhere says why.  Nor would copying them be right if
they could be read.  MDB is a private on-disk format, tied to the slapd that
wrote it and the architecture it was written on, and the point of a rebuild is
that the new guest is not the old one.

So the directory is exported instead.  C<ldap-export.sh> runs hourly and writes
C<slapcat> output to C</var/backups/ldap>, owned by the admin user, and that is
what C<remote_files> names.  On the next guest C<ldap-reload.sh> loads the data
half back with C<slapadd> before the seed runs, and the seed then does what it
was always supposed to do: fill in what is missing, rather than be the whole
directory.

The configuration database comes down beside the data and does not go back up.
C<cn=config> names the schema of the slapd that wrote it, the paths that slapd
was built with, and the TLS settings this recipe rewrites on every provision;
restoring a previous guest's copy over a new one is how you get a slapd that
will not start and will not say why.  It is exported so that an ACL or an
overlay somebody added is legible and can be put back deliberately.

An hour is therefore what a rebuild can lose, and only ever what changed in that
hour.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{admin_password}],
        properties => {
            admin_password => { type => 'string' },
            base_dn        => { type => 'string' },
            port           => { type => 'integer', default => 636 },
            users          => {
                type    => 'array',
                default => [],
                items   => {
                    type       => 'object',
                    properties => {
                        gecos         => { type => 'string' },
                        name          => { type => 'string' },
                        shell         => { type => 'string' },
                        ssh_import_id => { type => 'array', items => { type => 'string' } },
                        sudo          => { type => 'string' },
                    },
                },
            },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Derive base_dn from domain: example.com -> dc=example,dc=com
    #
    # split(/[.]/) and not split('.'): the first argument to split is a pattern,
    # and '.' as a pattern matches every character -- so this produced no parts
    # at all and an empty base_dn for any domain that did not set one.
    unless ( $opts{base_dn} ) {
        my $domain = $opts{domain} // '';
        my @parts  = split( /[.]/, $domain );
        $opts{base_dn} = join( ',', map { "dc=$_" } @parts );
    }

    # slapd derives its real base DN from the domain debconf is given, so that
    # has to be the domain base_dn describes rather than the guest hostname.
    # Configured separately they drift apart, and then the seed cannot bind:
    # "ldap_bind: Invalid credentials (49)", swallowed by the /bin/true after
    # it, leaving a directory with nothing in it.
    ( $opts{ldap_domain} = $opts{base_dn} ) =~ s/\bdc=//g;
    $opts{ldap_domain} =~ tr/,/./;

    return %opts;
}

# ssl-cert is here for its group, not for a certificate: it owns
# /etc/ssl/private, which Ubuntu ships 0710 root:ssl-cert, and slapd has to be
# in that group to read the key through it.  Without the package the group does
# not exist at all and `adduser openldap ssl-cert` fails outright.
sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # libldap2, not libldap-2.5-0: the soname is in the package name on
        # some distros and not on Ubuntu 24.04, where the archive has libldap2.
        return qw{slapd ldap-utils libldap2 ssl-cert};
    }
    die "Unsupported packager";
}

sub template_files {
    my ($self) = @_;
    return (
        'ldap.apparmor.tt'      => 'slapd.apparmor',
        'ldap.slapd.debconf.tt' => 'slapd.debconf',
        'ldap.seed.ldif.tt'     => 'seed.ldif',
        'ldap.tls.ldif.tt'      => 'tls.ldif',
        'ldap.export.sh.tt'     => 'ldap-export.sh',
        'ldap.export.cron.tt'   => 'ldap-export.cron',
        'ldap.reload.sh.tt'     => 'ldap-reload.sh',
    );
}

# An export taken now.  The cron runs hourly, and an hour of a directory is a
# password somebody changed and a key somebody added that a rebuild would put
# back the way they were.
sub remote_prepare {
    return ('/usr/local/sbin/ldap-export.sh');
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/ldap/' => 'ldap',
    );
}

sub tests {
    return qw{ldap.tt};
}

1;
