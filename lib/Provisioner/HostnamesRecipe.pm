package Provisioner::HostnamesRecipe;

#ABSTRACT: A recipe that needs every name that its domain answers for.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{uniq};

=head1 NAME

Provisioner::HostnamesRecipe - a recipe that needs every name that its domain
answers for

=head1 SYNOPSIS

    package Provisioner::Recipe::letsencrypt;
    use parent qw{Provisioner::Recipe Provisioner::HostnamesRecipe};

    sub args {
        my ($self) = @_;
        return (
            type       => 'object',
            properties => { $self->hostnames_property, ... },
        );
    }

    sub enrich {
        my ( $self, %opts ) = @_;
        $opts{domain_aliases} = [ $self->domain_aliases(%opts) ];
        return %opts;
    }

=head1 DESCRIPTION

A certificate, a zone, a mail server and the vhost of a domain each need every
name that the domain answers for.  Those names come from two places.  The
operator configures aliases in the C<aliases> of C<_global>.  And a recipe
declares the names that it serves in L<Provisioner::Recipe/subdomains>.

A recipe that needs the names inherits this class beside
L<Provisioner::Recipe>.  L<Provisioner::Recipe/configures> then hands it the
names of every recipe on the domain as C<hostnames>, if it is on the domain.
Nothing collects the names anywhere else.

A recipe names this class as its second parent, and it has only methods of
its own.  perl looks for a method in the first parent and all of its ancestors
before it looks in the second, so a method here that L<Provisioner::Recipe>
also has would never be called.  That is also why this class does not inherit
L<Provisioner::Recipe>.

=head2 %property = $recipe->hostnames_property()

The C<hostnames> option, for C<args>: the names that the recipes on the domain
serve, which they hand over themselves.

=cut

sub hostnames_property {
    return (
        hostnames => {
            type        => 'array',
            items       => { type => 'string' },
            default     => [],
            description => 'The names under the domain that the recipes on it serve.  Each recipe hands its own over: see configures in Provisioner::Recipe.  Not for an operator to write; configure an alias in the aliases of _global.',
        },
    );
}

=head2 @aliases = $recipe->domain_aliases(%opts)

Every name that the domain answers for, except the domain itself: the aliases
that the operator configured for the domain, in their order, then
C<hostnames>, sorted.  Each name comes once.

=cut

sub domain_aliases {
    my ( $self, %opts ) = @_;

    my $configured = $opts{aliases}{ $opts{domain} } // [];
    return grep { $_ ne $opts{domain} } uniq( @$configured, sort @{ $opts{hostnames} // [] } );
}

1;
