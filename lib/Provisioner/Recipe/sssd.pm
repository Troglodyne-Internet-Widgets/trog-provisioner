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

Or with sudo without a password for the owners of a GitHub organization, whom
L<Provisioner::Recipe::ldap> puts in C<github-admins>:

    somedomain:
        sssd:
            ldap_uri: ldaps://ldap.example.test
            base_dn: dc=example,dc=test
            sudo_groups:
                - github-admins

=head2 DESCRIPTION

Installs and configures SSSD with the C<ldap> identity provider so that LDAP
users can authenticate on this host.

Configures NSS and PAM to use SSSD to look up users and groups and to
authenticate them.  C<pam_mkhomedir> makes the home directory of a user at the
first login.

Set C<ldap_uri> to the LDAPS URI of your LDAP server (from the C<ldap> recipe).

sshd asks SSSD for the C<sshPublicKey> of a user with
C<sss_ssh_authorizedkeys>, so a user of the directory logs in with the keys
that the directory holds.  The C<authorized_keys> of the user still works too.

Each group in C<sudo_groups> gets sudo without a password, from
F</etc/sudoers.d/sssd>.  A user of the directory who is in none of them gets no
sudo at all, because such a user has no password to give it.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{ldap_uri base_dn}],
        properties => {
            ldap_uri      => { type => 'string', 'x-weak' => 1 },
            base_dn       => { type => 'string' },
            bind_dn       => { type => 'string' },
            bind_password => { type => 'string', 'x-secret' => 1 },

            sudo_groups => {
                type        => 'array',
                default     => [],
                items       => { type => 'string', pattern => '^[a-z_][a-z0-9_-]*$' },
                description => 'Groups of the directory whose members get sudo without a password on this guest.',
            },
        },
    );
}

sub template_files {
    my ($self) = @_;
    return (
        'sssd.conf.tt'    => 'sssd.conf',
        'sssd.sshd.tt'    => 'sssd.sshd.conf',
        'sssd.sudoers.tt' => 'sssd.sudoers',
    );
}

sub tests {
    return qw{sssd.tt};
}

1;
