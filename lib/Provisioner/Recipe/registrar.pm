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
            user: "secret:registrar/easydns_token/username"
            key:  "secret:registrar/easydns_token/password"

=head2 DESCRIPTION

The registrar holds the public zone of a domain, so dehydrated can write an
C<_acme-challenge> record into it.  This is one of the two implementations of
L<Provisioner::DNSRecipe>.  The other is L<Provisioner::Recipe::pdns>, where the
guest does the same job.

You usually write it once in C<_base>, and every domain inherits it, because a
fleet usually has one registrar.  A domain that its own C<pdns> serves needs
none.  A domain under a TLD that RFC 2606 reserves cannot use one, because no
public registrar holds a zone for C<.test>.

=head2 It installs nothing

A registrar is an external service, so this recipe configures nothing and
starts no service.  It supplies the credentials and C<lexicon_credentials>.
That makes it one of the two answers to L<Provisioner::DNSRecipe>.

The recipes that read those install what the guest needs: the shortcut of
L<Provisioner::Recipe::lexicon>, and the dehydrated hook of
L<Provisioner::Recipe::letsencrypt>.

=cut

=head2 %schema = $recipe->args()

Returns the schema of the configuration.  The C<description> of each key
documents it.

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

Returns C<type>, C<user> and C<key> as the operator configured them, with an
empty string for an unset C<user> or C<key>.  C<opts> is empty and C<extra> is
an empty list.

A registrar needs only a credential.  lexicon already knows where each of its
providers is, so there is no endpoint.  There are no flags, because the domain
is its own zone here.  C<--resolve-zone-name> spends live queries to find a
zone that is already known.

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

Returns lexicon.  An operator still edits a zone that a registrar holds, and
the lexicon shortcut is the tool for that.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    return ( lexicon => sub { return () }, $self->SUPER::required_recipes(%opts) );
}

1;
