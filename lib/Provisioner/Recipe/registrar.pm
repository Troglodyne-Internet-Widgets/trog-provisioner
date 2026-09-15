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

=head2 It installs almost nothing

A registrar is somewhere else, so there is nothing here to configure and no
service to start.  What the fragment does put on the guest is the convenience
shortcut every provider gets, F</opt/lexicon/E<lt>domainE<gt>/E<lt>typeE<gt>>,
so an operator can list and edit records by hand with the credentials already
filled in.

The credentials themselves reach dehydrated through
L<Provisioner::Recipe::letsencrypt>'s hook rather than through anything here.

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

=head2 %opts = $recipe->enrich(%opts)

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{lexicon} = { $self->lexicon_credentials(%opts) };

    return %opts;
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return ( 'lexicon.shortcut.sh.tt' => 'lexicon.sh' );
}

=head2 @tests = $recipe->tests()

=cut

sub tests {
    return qw{registrar.tt};
}

1;
