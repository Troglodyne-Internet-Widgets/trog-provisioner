package Provisioner::SSLRecipe;

#ABSTRACT: Base class for a recipe that issues the certificate of a domain.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::SSLRecipe - which recipe issues the certificate of a domain.

=head1 SYNOPSIS

    package Provisioner::Recipe::letsencrypt;
    use parent qw{Provisioner::SSLRecipe};

    # And in a recipe that needs a certificate:
    sub required_recipes {
        my ( $self, %opts ) = @_;
        return ( 'Provisioner::SSLRecipe' => sub { return ( hostnames => ["webmail.$opts{domain}"] ) } );
    }

=head1 DESCRIPTION

A recipe that serves a name needs a certificate that names it.  It requires
this interface, and the depsolver resolves the interface to the recipe that
issues certificates for the domain.  The base class of every recipe does this
for the C<subdomains> of the recipe.  See C<hostnames> in L<Provisioner::Recipe>.

An implementation takes the names in C<hostnames>.  Declare it with
C<hostnames_property> of L<Provisioner::Recipe>.

L<Provisioner::Recipe::letsencrypt> is the only implementation.

=head2 $name = $recipe->implementation_for(%opts)

Returns the recipe that issues the certificate of C<$opts{domain}>:
C<letsencrypt>.  C<resolve_substitutable_dependency> in L<Provisioner::Cookbook>
asks it.

=cut

our $IMPLEMENTATION = 'letsencrypt';

sub implementation_for {
    return $IMPLEMENTATION;
}

1;
