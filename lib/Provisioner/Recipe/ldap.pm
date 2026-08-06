package Provisioner::Recipe::ldap;

use strict;
use warnings;

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

=cut

sub args {
    return (
        type     => 'object',
        required => [qw{admin_password}],
        properties => {
            admin_password => { type => 'string' },
            base_dn        => { type => 'string' },
            port           => { type => 'integer', default => 636 },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Derive base_dn from domain: example.com -> dc=example,dc=com
    unless ( $opts{base_dn} ) {
        my $domain = $opts{domain} // '';
        my @parts = split /\./, $domain;
        $opts{base_dn} = join( ',', map { "dc=$_" } @parts );
    }

    $opts{port} //= 636;
    $opts{users} //= [];

    return %opts;
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{slapd ldap-utils libldap-2.5-0};
    }
    die "Unsupported packager";
}

sub template_files {
    my ($self) = @_;
    return (
        'ldap.slapd.debconf.tt' => 'slapd.debconf',
        'ldap.seed.ldif.tt'     => 'seed.ldif',
        'ldap.tls.ldif.tt'      => 'tls.ldif',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/etc/ldap/slapd.d/' => 'ldap-slapd.d',
    );
}

sub tests {
    return qw{ldap.tt};
}

1;
