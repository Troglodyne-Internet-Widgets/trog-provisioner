package Provisioner::Recipe::Ubuntu::ldap;

#ABSTRACT: What ldap needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ldap};

=head1 NAME

Provisioner::Recipe::Ubuntu::ldap - Ubuntu's C<deps> for L<Provisioner::Recipe::ldap>.

=cut

=head2 $recipe->deps(%opts)

C<slapd>, C<ldap-utils>, C<libldap2>, and C<ssl-cert> for its group, which
slapd must be in to read its key.  With C<github>, also perl and the JSON and
TLS libraries that F<ldap-github-sync> runs with.

=over 4

=item github - HashRef|Undef - the organization whose members get accounts;
only whether it is set counts here

=back

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps( github => { org => 'example' } );

=cut

sub deps {

    my ( $self, %opts ) = @_;

    # libldap2 is the name in the Ubuntu 24.04 archive.  ssl-cert is here for
    # its group, which slapd must be in to read the key in /etc/ssl/private.
    # ldap-github-sync is perl, and HTTP::Tiny needs IO::Socket::SSL for https.
    return ( qw{slapd ldap-utils libldap2 ssl-cert}, ( $opts{github} ? qw{perl libjson-perl libio-socket-ssl-perl} : () ) );
}

1;
