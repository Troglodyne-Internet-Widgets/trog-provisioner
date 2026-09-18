package Provisioner::Recipe::nostubresolver;

#ABSTRACT: Turn off the stub resolver of systemd-resolved.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

=head1 Provisioner::Recipe::nostubresolver

=head2 SYNOPSIS

    somedomain:
        nostubresolver:

=head2 DESCRIPTION

Turns off the "stub resolver" of systemd-resolved, which listens on
127.0.0.53:53.  systemd-resolved keeps running.

Use it when you install a real DNS server, such as pdns, which needs port 53.
Also use it on a network where the default behavior of the stub causes
problems.

=head2 What answers instead

Turning the stub off is safe only when something else answers.  So this recipe
writes the C<resolvers> setting that every guest is built from, and no
addresses of its own.

On a guest that runs its own C<pdns>, C<127.0.0.1> goes first.  That guest is
the only authoritative server for its own domain.  Any other resolver has no
answer for that zone.  L<Provisioner::Recipe::letsencrypt> writes an
C<_acme-challenge> record through the local API and must then see it served.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'nostubresolver.tt' => '10-disable-stub-resolver.conf',
    );
}

=head2 %opts = $recipe->enrich(%opts)

Returns %opts with C<resolvers> as an array reference.  C<resolvers> can come
in as an array reference, or as a string separated by commas or spaces.  If
C<modules> includes C<pdns>, C<127.0.0.1> goes first, unless the list already
has it.

Dies if the list is empty.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @resolvers =
      ref $opts{resolvers} eq 'ARRAY'
      ? @{ $opts{resolvers} }
      : grep { $_ } split( m/[,\s]+/, $opts{resolvers} // q{} );

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
