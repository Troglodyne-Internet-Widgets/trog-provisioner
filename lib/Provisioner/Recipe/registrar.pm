package Provisioner::Recipe::registrar;

#ABSTRACT: The registrar holding a domain's public zone, and how lexicon reaches it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::DNSRecipe};

use Provisioner::Cookbook();

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

=head2 A pdns guest can be the registrar

A domain under a zone in the C<authoritative_for> of a pdns guest has that
guest as its registrar, whatever C<type> says.  See
L<Provisioner::Cookbook/delegating_guest>.  It reaches the API of that guest
through its API proxy, with a token of its own name.  See
L<Provisioner::Recipe::pdns/The API proxy>.  Such a
domain needs no configuration here.  So C<type> is required only for a domain
that no pdns guest holds.

=head2 It installs nothing, and publishes the records of the domain

A registrar is an external service, so this recipe configures nothing and
starts no service.  It supplies the credentials and C<lexicon_credentials>.
That makes it one of the two answers to L<Provisioner::DNSRecipe>.

When it holds the zone of the domain, it publishes the C<A> record of the domain
and a C<CNAME> for each of its names, through the lexicon shortcut.  See
C<publication> in L<Provisioner::DNSRecipe>, which also says how to publish
another address.

=cut

=head2 %schema = $recipe->args()

Returns the schema of the configuration.  The C<description> of each key
documents it.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            type => {
                type        => 'string',
                description => 'The provider name dns-lexicon knows this registrar by -- easydns, route53, cloudflare.  It names the environment variables lexicon reads and the shortcut installed for it, so it has to be what lexicon calls them rather than what you do.  Required, except for a domain that a pdns guest holds, which goes to that guest.',
            },
            user => {
                type        => 'string',
                default     => q{},
                description => 'The account, where the provider wants one alongside the token.  Empty is normal: most of them authenticate with a token alone.',
            },
            key => {
                type        => 'string',
                'x-secret'  => 1,
                default     => q{},
                description => 'The token lexicon authenticates with.  A secret: reference rather than the value, so it lives in the store and not in the configuration.',
            },
        },
    );
}

=head2 %credentials = $recipe->lexicon_credentials(%opts)

For a domain that a pdns guest holds, returns what
L<Provisioner::Recipe::pdns/client_credentials> returns for that guest.
Otherwise returns C<configured_credentials>.

A registrar needs only a credential.  lexicon already knows where each of its
providers is, so there is no endpoint.  There are no flags, because the domain
is its own zone here.  C<--resolve-zone-name> spends live queries to find a
zone that is already known.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    my $guest = $self->delegated_to( $opts{domain} );
    return Provisioner::Cookbook->load('pdns')->client_credentials( $guest, $opts{domain} ) if defined $guest;

    return $self->configured_credentials(%opts);
}

=head2 %credentials = $recipe->configured_credentials(%opts)

Returns C<type>, C<user> and C<key> as the operator configured them, with an
empty string for an unset C<user> or C<key>.  C<opts> is empty and C<extra> is
an empty list.  Dies when there is no C<type>.

L<Provisioner::Recipe::pdns> asks this for the delegation of a zone that it
holds, which C<lexicon_credentials> would send to itself.

=cut

sub configured_credentials {
    my ( $self, %opts ) = @_;

    die "registrar has no type for $opts{domain}, and no pdns guest holds that name.  Name the provider that holds its zone, as lexicon calls it.\n"
      unless $opts{type};

    return (
        type  => $opts{type},
        user  => $opts{user} // q{},
        key   => $opts{key}  // q{},
        opts  => q{},
        extra => [],
    );
}

=head2 $guest = $recipe->delegated_to($domain)

The pdns guest that holds C<$domain> through its C<authoritative_for>, or undef.
A pdns guest is never delegated to itself, nor is a domain on it.

=cut

sub delegated_to {
    my ( $self, $domain ) = @_;

    my $guest = Provisioner::Cookbook->delegating_guest($domain);
    return unless defined $guest;
    return if $guest eq ( Provisioner::Cookbook->host_of($domain) // $domain );
    return $guest;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

For a domain that a pdns guest holds, and that this recipe answers for, the
token of the domain.  See L<Provisioner::Recipe::pdns/client_secret>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    return () unless defined $self->delegated_to($domain) && $self->provider_for( domain => $domain ) eq $self->recipe_name;

    my ( $guest, $zone ) = Provisioner::Cookbook->delegating_guest($domain);
    return Provisioner::Cookbook->load('pdns')->client_secret( $guest, $zone, $domain );
}

=head2 %opts = $recipe->enrich(%opts)

Adds what C<publication> in L<Provisioner::DNSRecipe> says this recipe
publishes.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    return ( %opts, $self->publication(%opts) );
}

sub tests {
    return qw{registrar.tt};
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
