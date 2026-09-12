package Provisioner::Recipe::nostubresolver;

#ABSTRACT: Remove systemd's stub resolver.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

=head1 Provisioner::Recipe::nostubresolver

=head2 SYNOPSIS

    somedomain:
        nostubresolver:

=head2 DESCRIPTION

Remove systemd's "stub resolver".

Particularly useful if you plan on installing an actual DNS server, such as pdns.

Also useful in network environments where its default behavior is unhelpful.

=head2 What answers instead

Turning the stub off is only safe when something else is answering, so this
writes the resolvers this installation is configured with -- the C<resolvers>
setting every guest is built from -- rather than a pair of addresses chosen
here.

On a guest that runs its own C<pdns>, C<127.0.0.1> goes first.  That guest is
authoritative for its own domain and nothing else in the fleet is, so a lookup
sent anywhere else comes back with no answer for the one zone the guest most
needs to read: L<Provisioner::Recipe::letsencrypt> writes an
C<_acme-challenge> record through the local API and then has to see it served.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'nostubresolver.tt' => '10-disable-stub-resolver.conf',
    );
}

=head2 %opts = $recipe->enrich(%opts)

C<resolvers> as the list the template writes: coerced to one, with the guest
itself in front when it runs the DNS server that answers for it.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @resolvers =
      ref $opts{resolvers} eq 'ARRAY'
      ? @{ $opts{resolvers} }
      : grep { length } split( m/[,\s]+/, $opts{resolvers} // q{} );

    unshift( @resolvers, '127.0.0.1' )
      if ( any { $_ eq 'pdns' } @{ $opts{modules} // [] } )
      && !any { $_ eq '127.0.0.1' } @resolvers;

    die "nostubresolver: taking the stub listener away leaves a guest with whatever else answers, and this installation names no resolvers.\n" unless @resolvers;

    $opts{resolvers} = \@resolvers;
    return %opts;
}

sub tests {
    return qw{nostubresolver.tt};
}

1;
