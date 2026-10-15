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
for the C<subdomains> of the recipe.  See C<served_names> in L<Provisioner::Recipe>.

An implementation takes the names in its C<hostnames> option, which C<schema>
declares.

L<Provisioner::Recipe::letsencrypt> is the only implementation.

=head2 %schema = $recipe->schema()

The schema of L<Provisioner::Recipe>, with the C<hostnames> option added: the
names that the recipes on the domain serve.  The base class hands them to
every implementation, so an implementation does not declare the option.

=cut

sub schema {
    my ($self) = @_;

    my %schema = $self->SUPER::schema();
    $schema{properties}{hostnames} = {
        type        => 'array',
        items       => { type => 'string' },
        default     => [],
        description => 'The names under the domain that the recipes on it serve.  Each recipe hands its own over: see served_names in Provisioner::Recipe.  Not for an operator to write; configure an alias in the aliases of _global.',
    };

    return %schema;
}

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
