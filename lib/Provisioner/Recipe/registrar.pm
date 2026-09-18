package Provisioner::Recipe::registrar;

#ABSTRACT: The registrar holding a domain's public zone, and how lexicon reaches it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::DNSRecipe};

=head1 Provisioner::Recipe::registrar

=head2 SYNOPSIS

    _base:
        registrar:
            type: easydns
            user: "secret:troglodyne/easydns_token/username"
            key:  "secret:troglodyne/easydns_token/password"

=head2 DESCRIPTION

Whoever holds the public zone for a domain, so dehydrated can write an
C<_acme-challenge> record into it.  One of the two implementations of
L<Provisioner::DNSRecipe>; the other is L<Provisioner::Recipe::pdns>, which is
the same job done by the guest itself.

Ordinarily written once in C<_base> and inherited by every domain, since a fleet
usually has one registrar.  A domain served by its own C<pdns> needs none, and a
domain under a TLD RFC 2606 reserves can never use one -- no public registrar
holds a zone for C<.test>.

=head2 It installs nothing

A registrar is somewhere else, so there is nothing here to configure and no
service to start.  This recipe is the credentials and C<lexicon_credentials>,
which is what makes it one of the two answers to L<Provisioner::DNSRecipe>.

What is installed on the guest is installed by the recipes that read those:
L<Provisioner::Recipe::lexicon>'s shortcut, and
L<Provisioner::Recipe::letsencrypt>'s dehydrated hook.

=cut

=head2 %schema = $recipe->args()

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{type}],
        properties => {
            type => {
                type        => 'string',
                description => 'The provider name dns-lexicon knows this registrar by -- easydns, route53, cloudflare.  It names the environment variables lexicon reads and the shortcut installed for it, so it has to be what lexicon calls them rather than what you do.',
            },
            user => {
                type        => 'string',
                default     => q{},
                description => 'The account, where the provider wants one alongside the token.  Empty is normal: most of them authenticate with a token alone.',
            },
            key => {
                type        => 'string',
                default     => q{},
                description => 'The token lexicon authenticates with.  A secret: reference rather than the value, so it lives in the store and not in the configuration.',
            },
        },
    );
}

=head2 %credentials = $recipe->lexicon_credentials(%opts)

What the operator configured, which is all there is to say: a registrar is
reached over the internet with a credential and nothing else.  No endpoint,
because lexicon already knows where its providers live, and no flags -- the
domain is its own zone here, so C<--resolve-zone-name> would spend live queries
working out something already known.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    return (
        type  => $opts{type},
        user  => $opts{user} // q{},
        key   => $opts{key}  // q{},
        opts  => q{},
        extra => [],
    );
}

=head2 %required = $recipe->required_recipes(%opts)

lexicon: a domain whose zone somebody else holds still has an operator who wants
to edit it, and that shortcut is what they reach for.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    return ( lexicon => sub { return () }, $self->SUPER::required_recipes(%opts) );
}

1;
