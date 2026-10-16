package Provisioner::Recipe::registrar;

#ABSTRACT: The registrar holding a domain's public zone, and how lexicon reaches it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::DNSRecipe};

use File::Copy();
use List::Util qw{any uniq};

use Provisioner::Cookbook();
use Provisioner::DNSRecipe();
use Provisioner::Utils();

=head1 Provisioner::Recipe::registrar

=head2 SYNOPSIS

    _base:
        registrar:
            type: easydns
            user: "secret:registrar/easydns_token/username"
            key:  "secret:registrar/easydns_token/password"

    web.lab.example.net:
        registrar:
            authority: ns.example.net

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

C<authority> names a guest of this installation that runs
L<Provisioner::Recipe::pdns>.  That guest then holds a zone of the name of this
domain, and this domain writes its records there, through the API proxy of that
guest, with a token of its own.  See L<Provisioner::Recipe::pdns/Zones of other
guests>.  C<bin/provision> makes the zone and the token when it builds this
guest, and C<bin/destroy> removes them.  The setting names that guest, so
C<bin/provision> builds that guest first.  See
L<Provisioner::Cookbook/named_guests>.

The domain needs at least three labels, as C<web.example.net> does.  Its zone
is then delegated from the zone of the registered domain, with an C<NS> record
that names the authority.  The guest writes that record in its postrun,
through the registrar that C<type>, C<user> and C<key> name, which is usually
the one of C<_base>.  Under a reserved TLD there is no zone above to write to,
and the guest writes none.  A registered domain itself is delegated at the
registry, with glue records, which most registrars have no API for.  So the
recipe refuses a domain of two labels.

The guest asks the authority for the names in its own zone, and for the names
of the authority itself where the authority holds its own zone.  A drop-in of
systemd-resolved routes those names there.  So lexicon finds the API of the
authority, and the zone of a name, before any public resolver knows of them,
and also under a reserved TLD.

A pdns guest under a reserved TLD serves the API with a certificate from its own
CA, which the fleet authority signs.  See L<Provisioner::Recipe::acmeca>.  So a
domain whose authority is such a guest gets that authority as a trust anchor,
at the path where acmeca installs it.

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
                description =>
                  'The provider name dns-lexicon knows this registrar by -- easydns, route53, cloudflare.  It names the environment variables lexicon reads and the shortcut installed for it, so it has to be what lexicon calls them rather than what you do.  Required, except under a reserved TLD with an authority.  With an authority, it is the registrar that the NS record of the zone of the domain goes to.',
            },
            authority => {
                type        => 'string',
                format      => 'hostname',
                description => 'A guest of this installation that runs pdns, and holds a zone of the name of this domain.  This domain then writes its records there, and resolves the names of that zone through it.  The domain needs at least three labels.',
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

For a domain with an C<authority>, returns what
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

C<enrich> asks this for the registrar of the zone above, where the C<NS>
record of a domain with an C<authority> goes.

=cut

sub configured_credentials {
    my ( $self, %opts ) = @_;

    die "registrar has no type for $opts{domain}.  Name the provider that holds the zone, as lexicon calls it.\n"
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

The C<authority> of the registrar of C<$domain>, or of the guest that it is
layered onto, or undef.  A guest is never its own authority.

=cut

sub delegated_to {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    foreach my $where ( uniq( $domain, $server ) ) {
        my $authority = ( Provisioner::Cookbook->domain_config($where)->{ $self->recipe_name } // {} )->{authority};
        next unless defined $authority;
        $authority = Provisioner::Utils::dns_name($authority);
        return $authority eq $server ? undef : $authority;
    }

    return;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

For a domain with an C<authority>, where this recipe holds the zone, the token
of the domain, which the authority issues.  See
L<Provisioner::Recipe::pdns/client_secret>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    my $guest = $self->delegated_to($domain);
    return () unless defined $guest && $self->provider_for( domain => $domain ) eq $self->recipe_name;

    return Provisioner::Cookbook->load('pdns')->client_secret( $guest, Provisioner::Utils::dns_name($domain) );
}

=head2 %opts = $recipe->enrich(%opts)

Adds what C<publication> in L<Provisioner::DNSRecipe> says this recipe
publishes.  With an C<authority>, adds C<authority>, C<authority_address>, its
address, C<routing_domains>, the zones that the guest asks it for, as
systemd-resolved spells them,
C<fleet_anchor>, which is true where the authority is under a reserved TLD,
C<upstream>, the credentials of the registrar of the zone above, or undef where
the domain is under a reserved TLD, and C<parent>, the name above the domain.

Dies when the domain has fewer than three labels, when the authority runs no
pdns, or when the installation gave the authority no address.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain};
    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my $guest  = defined $opts{authority} ? Provisioner::Utils::dns_name( $opts{authority} ) : $self->delegated_to($domain);
    undef $guest if defined $guest && $guest eq $server;
    return ( %opts, $self->publication(%opts) ) unless defined $guest;

    die "$domain names $guest as the authority of its registrar, but has fewer than three labels.  Its zone is delegated with an NS record in the zone of a registered domain, and a registered domain itself needs glue at the registry, which most registrars have no API for.\n"
      if ( $domain =~ tr/.// ) < 2;
    die "$domain names $guest as the authority of its registrar, but $guest runs no pdns in this installation.\n"
      unless exists Provisioner::Cookbook->domain_config($guest)->{pdns};

    my $address = ( $opts{ipmap} // {} )->{$guest};
    die "$domain names $guest as the authority of its registrar, and the installation gave $guest no address to ask it at.  Give it an address of the pool.\n"
      unless $address;

    my %reserved = map { $_ => 1 } $self->reserved_tlds;
    my $own_zone = ( eval { $self->provider_for( domain => $guest ) } // q{} ) eq Provisioner::DNSRecipe->local_implementation;

    $opts{authority}         = $guest;
    $opts{authority_address} = $address;
    $opts{routing_domains}   = join( q{ }, map { "~$_" } $domain, ( $own_zone ? $guest : () ) );
    $opts{fleet_anchor}      = $reserved{ Provisioner::Utils::tld_of($guest)  // q{} } ? 1     : 0;
    $opts{upstream}          = $reserved{ Provisioner::Utils::tld_of($domain) // q{} } ? undef : { $self->configured_credentials( %opts, domain => $domain ) };
    $opts{parent}            = $domain =~ s/\A[^.]+[.]//r;

    return ( %opts, $self->publication(%opts) );
}

=head2 @written = $recipe->generate_files($output_dir, %vars)

Writes the templates, and the certificate of the fleet authority as
F<registrar-anchor.crt> where C<enrich> sets C<fleet_anchor>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated(%vars);
    return @written unless $opts{fleet_anchor};

    my $authority = Provisioner::Cookbook->load('fetchcache')->authority();
    File::Copy::copy( $authority->{cert}, "$output_dir/registrar-anchor.crt" )
      or die "Could not give the guest the authority that the API of its pdns guest chains to: $!\n";

    return ( @written, 'registrar-anchor.crt' );
}

sub template_files {
    return (
        'registrar.resolved.tt' => 'registrar-resolved.conf',
        'registrar.upstream.tt' => 'registrar-upstream.sh',
    );
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
