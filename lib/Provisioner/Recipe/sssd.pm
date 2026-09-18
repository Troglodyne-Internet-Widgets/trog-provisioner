package Provisioner::Recipe::sssd;

#ABSTRACT: Configure SSSD so LDAP users can authenticate on the host.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::sssd

=head2 SYNOPSIS

    somedomain:
        sssd:
            ldap_uri: ldaps://ldap.example.test
            base_dn: dc=example,dc=test

Or with a bind DN, so that searches authenticate:

    somedomain:
        sssd:
            ldap_uri: ldaps://ldap.example.test
            base_dn: dc=example,dc=test
            bind_dn: cn=readonly,dc=example,dc=test
            bind_password: readonlypass

=head2 DESCRIPTION

Installs and configures SSSD with the C<ldap> identity provider so that LDAP
users can authenticate on this host.

Configures NSS and PAM to use SSSD to look up users and groups and to
authenticate them.  C<pam_mkhomedir> makes the home directory of a user at the
first login.

Set C<ldap_uri> to the LDAPS URI of your LDAP server (from the C<ldap> recipe).

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{ldap_uri base_dn}],
        properties => {
            ldap_uri      => { type => 'string' },
            base_dn       => { type => 'string' },
            bind_dn       => { type => 'string' },
            bind_password => { type => 'string' },
        },
    );
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
