package Provisioner::Recipe::dnsrecords;

#ABSTRACT: Publish this guest's own address records to whoever holds its zone.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::dnsrecords

=head2 SYNOPSIS

    somedomain:
        dnsrecords:

=head2 DESCRIPTION

Put this guest on the map: an C<A> record for the domain at the address it was
built with, and a C<CNAME> for each of its aliases.  Written through lexicon, to
whichever recipe holds the zone -- see L<Provisioner::DNSRecipe/credentials_for>.

=head2 It runs for a guest that serves its own zone as well

L<Provisioner::Recipe::pdns> writes these records once, out of
F<templates/files/pdns.zone.tt>, and only into a database that does not already
answer for the domain.  So a rebuilt guest keeps whatever its restored
F<zones.db> held, and an address that changed between builds is never corrected
by anything.  pdns says as much where it declines to reload the zone:

    A zone that is already there and needs changing is a job for lexicon.

This is that job.  On a first build there is nothing to do -- the record pdns
wrote is the record this would write, so it sends nothing -- and on a rebuild it
is what puts the new address where the zone can serve it.

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

=head2 Where it does not run

Where there is no address to publish.  A hypervisor that allocates addresses
itself -- a cloud -- leaves C<main_ip> empty at generate time, so the fragment is
empty rather than guessing at one.

Which provider holds the zone decides nothing here.  It used to: this stayed out
of the way wherever that was the guest's own pdns, on the grounds that the
zonefile had already written the same records.  True of a first build and false
of every one after it, for the reason above.

=cut

=head2 %opts = $recipe->enrich(%opts)

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{publish_records} = $opts{main_ip} ? 1 : 0;

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
