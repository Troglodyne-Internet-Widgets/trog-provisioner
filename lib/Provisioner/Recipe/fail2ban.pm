package Provisioner::Recipe::fail2ban;

#ABSTRACT: Set up fail2ban jails for the services on the guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::fail2ban

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        fail2ban:

That is usually all.  The recipes of the domain say which jails they need.

=head2 DESCRIPTION

Sets up fail2ban with a jail for each service on the guest that takes logins or
requests from the internet, and bans through ufw.

Each recipe with such a service declares its jails in C<jails>, and so depends
on this recipe, as a recipe that listens depends on C<ufw>.  See C<jails> in
L<Provisioner::Recipe>.  This recipe writes the jails of the domain into one file
in F</etc/fail2ban/jail.d/>.  A jail can also be named here, under C<jails>, with
the same options.

Every jail bans through ufw, not the C<nftables> that Ubuntu sets as the default.
So a ban and the rate limits of C<ufw> are in one firewall.  fail2ban on Ubuntu
enables its C<sshd> jail by default, and that jail bans through ufw too.

=head1 METHODS

=head2 args()

The schema of the options: C<jails>, a map from the name of each jail to its
settings, each a string or an integer.  It is empty by default, and the jails
of the other recipes of the domain fill it in.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # Filled in from the jails of every recipe on the guest.  A jail
            # name is a section of an INI file, so it takes no brackets.
            jails => {
                type              => 'object',
                default           => {},
                patternProperties => {
                    '^[\w.-]+$' => {
                        type                 => 'object',
                        additionalProperties => { type => [qw{string integer}] },
                    },
                },
                additionalProperties => 0,
            },
        },
    );
}

=head2 template_files()

The one file of jails, which takes no list of recipes: F<jail.cfg> from
F<fail2ban.jail.tt>.

Returns a list of pairs, from the template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    my ($self) = @_;

    return ( 'fail2ban.jail.tt' => 'jail.cfg' );
}

=head2 tests()

Returns a list of the test templates that run on the guest: F<fail2ban.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{fail2ban.tt};
}

1;
