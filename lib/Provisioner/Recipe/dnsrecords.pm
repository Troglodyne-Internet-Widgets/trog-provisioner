package Provisioner::Recipe::dnsrecords;

#ABSTRACT: Publish this guest's own address records to whoever holds its zone.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::DNSRecipe();

=head1 Provisioner::Recipe::dnsrecords

=head2 SYNOPSIS

    somedomain:
        dnsrecords:

=head2 DESCRIPTION

Put this guest on the map: an C<A> record for the domain at the address it was
built with, and a C<CNAME> for each of its aliases.  Written through lexicon, to
whichever recipe holds the zone -- see L<Provisioner::DNSRecipe/credentials_for>.

L<Provisioner::Recipe::pdns> already does this for a guest that serves its own
zone: it builds the whole thing from F<templates/files/pdns.zone.tt>.  What was
missing is the other case, where somebody else holds the zone and the records
had to be added by hand.

=head2 What it publishes, and what it leaves alone

The address and the aliases, and nothing else.

B<No C<ns1>.>  pdns publishes one because a guest serving its own zone is its own
nameserver, delegated.  A zone a registrar holds has nameservers of theirs, and
advertising the guest as one would be a claim this recipe is in no position to
make.

B<Nothing is ever deleted, and nothing is overwritten except a record of ours
that has the wrong content.>  The zone belongs to whoever configured it, and it
will hold records this knows nothing about.  A record that is already right is
left alone rather than rewritten, so a rebuild from the same configuration sends
nothing at all.

=head2 The address is published whatever subnet it is on

C<main_ip> is what the guest was built with, and on a fleet behind NAT that is an
RFC 1918 address.  It goes up as it stands: a zone holding internal addresses for
internal names is ordinary practice, and it is the address the thing asking is
going to need.

A hypervisor that allocates addresses itself -- a cloud -- leaves C<main_ip>
empty at generate time, and there is then nothing to publish.  The fragment is
empty in that case rather than guessing.

=head2 Where it does not run

A guest whose zone is served by L<Provisioner::Recipe::pdns> already has these
records, built from the zonefile, so this stays out of the way: the fragment is
empty wherever the provider holding the zone is the local one.

=cut

=head2 %opts = $recipe->enrich(%opts)

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $provider = Provisioner::DNSRecipe->provider_for(%opts);
    my $address  = $opts{main_ip} // q{};

    $opts{publish_records} = ( $provider ne Provisioner::DNSRecipe->local_implementation() && $address ) ? 1 : 0;

    return %opts;
}

=head2 %required = $recipe->required_recipes(%opts)

lexicon: the client this writes the records with, and the per-domain shortcut it
reads the credential out of.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    return ( lexicon => sub { return () }, $self->SUPER::required_recipes(%opts) );
}

=head2 @tests = $recipe->tests()

=cut

sub tests {
    return qw{dnsrecords.tt};
}

1;
