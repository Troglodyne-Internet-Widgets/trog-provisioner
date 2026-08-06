package Provisioner::Recipe::sssd;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::sssd

=head2 SYNOPSIS

    somedomain:
        sssd:
            ldap_uri: ldaps://ldap.example.com
            base_dn: dc=example,dc=com

Or with a bind DN for authenticated searches:

    somedomain:
        sssd:
            ldap_uri: ldaps://ldap.example.com
            base_dn: dc=example,dc=com
            bind_dn: cn=readonly,dc=example,dc=com
            bind_password: readonlypass

=head2 DESCRIPTION

Installs and configures SSSD with the C<ldap> identity provider so that LDAP
users can authenticate on this host.

Configures NSS and PAM to use SSSD for user/group lookups and authentication.
Home directories are created automatically on first login via C<pam_mkhomedir>.

Set C<ldap_uri> to the LDAPS URI of your LDAP server (from the C<ldap> recipe).

=cut

sub args {
    return (
        type     => 'object',
        required => [qw{ldap_uri base_dn}],
        properties => {
            ldap_uri      => { type => 'string' },
            base_dn       => { type => 'string' },
            bind_dn       => { type => 'string' },
            bind_password => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;
    return %opts;
}

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{sssd sssd-ldap libpam-sss libnss-sss};
    }
    die "Unsupported packager";
}

sub template_files {
    my ($self) = @_;
    return (
        'sssd.conf.tt' => 'sssd.conf',
    );
}

sub tests {
    return qw{sssd.tt};
}

1;
