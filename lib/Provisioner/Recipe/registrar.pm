package Provisioner::Recipe::registrar;

#ABSTRACT: Which server holds the zone of a domain, how lexicon reaches it, and its records.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Copy();
use List::Util qw{uniq};

use Provisioner::Cookbook();
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

This recipe is the DNS client of a domain.  It says which server holds the
zone of the domain, it gives lexicon the credentials for that server, and it
publishes the records of the domain there.  So dehydrated can write an
C<_acme-challenge> record into the zone.  Every recipe that serves a name
requires this recipe, and so does L<Provisioner::Recipe::letsencrypt>.

One of three servers holds the zone.  C<authority_of> decides which:

=over 4

=item * The C<pdns> of the guest itself, where C<authority> names the guest, or
where the guest is under a reserved TLD and names no C<authority>.  No public
registrar holds a zone for C<.test>.  The guest must then run C<pdns>, as
another guest must that C<authority> names.

=item * The C<pdns> of another guest, which C<authority> names.  See below.

=item * The registrar that C<type>, C<user> and C<key> name.  You usually write
those once in C<_base>, and every domain inherits them, because a fleet usually
has one registrar.

=back

A guest that runs pdns does not hold its own zone for that reason alone.  It
can be the authority of other guests while a public registrar holds its own
name.  A guest that does hold its own zone names itself as its C<authority>.

=head2 A pdns guest can be the registrar

C<authority> names a guest of this installation that runs
L<Provisioner::Recipe::pdns>.  That guest then holds a zone of the name of this
domain, and this domain writes its records there, through the API proxy of that
guest, with a token of its own.  See L<Provisioner::Recipe::pdns/Zones of other
guests>.  C<bin/provision> makes the zone and the token when it builds this
guest, and C<bin/destroy> removes them.  The setting names that guest, so
C<bin/provision> builds that guest first.  See
L<Provisioner::Cookbook/named_guests>.

The guest asks the authority for the names in its own zone, and for the names
of the authority itself where the authority holds its own zone.  A drop-in of
systemd-resolved routes those names there.  So lexicon finds the API of the
authority, and the zone of a name, before any public resolver knows of them,
and also under a reserved TLD.

A pdns guest under a reserved TLD serves the API with a certificate from its own
CA, which the fleet authority signs.  See L<Provisioner::Recipe::acmeca>.  So a
domain whose authority is such a guest gets that authority as a trust anchor,
at the path where acmeca installs it.

=head2 The zone above delegates the zone

Where a pdns of this installation holds the zone of a domain, on the guest
itself or on another guest, the zone of the registered domain delegates it with
an C<NS> record.  The record names the authority, or C<ns1> of a guest that
holds its own zone.  Where that name is inside the zone, as C<ns1> is, an C<A>
record of it in the zone above tells a resolver where to ask.  That record is
glue in the zone above, not at the registry.  The guest writes both through
the registrar that C<type>, C<user> and C<key> name, which is usually the one
of C<_base>.  It writes them first in its postrun, in slot 0, which is before
the tasks of every target.  The fetcher of L<Provisioner::Recipe::letsencrypt>
runs in the postrun as well, and the CA looks for the challenge through the
zone above.  letsencrypt requires this recipe, so the fetcher otherwise runs
first, and the CA finds no zone.  The delegation needs only lexicon and the
shortcut of the zone above, and both are on the guest before the postrun
starts.  Under a reserved TLD there is no zone above to write to, and the
guest writes none.

So the domain needs at least three labels, as C<web.example.net> does.  A
registered domain itself is delegated at the registry, with glue records, which
most registrars have no API for.  So the recipe refuses a domain of two labels
outside a reserved TLD.

=head2 It installs nothing, and publishes the records of the domain

This recipe starts no service.  It supplies the credentials in
C<lexicon_credentials>, and the server that holds the zone is a service of its
own.

It publishes the C<A> record of the domain and a C<CNAME> for each of its
names, through the lexicon shortcut.  See C<publication>, which also says how
to publish another address.

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
                  'The provider name dns-lexicon knows this registrar by -- easydns, route53, cloudflare.  It names the environment variables lexicon reads and the shortcut installed for it, so it has to be what lexicon calls them rather than what you do.  Required where this registrar holds the zone.  Where a pdns of this installation holds it, outside a reserved TLD, it is the registrar that the NS record of the zone of the domain goes to, so it is required there too.',
            },
            authority => {
                type        => 'string',
                format      => 'hostname',
                description =>
                  'A guest of this installation that runs pdns, and holds a zone of the name of this domain.  This domain then writes its records there, and resolves the names of that zone through it.  Where this names the guest itself, its own pdns holds its zone.  Outside a reserved TLD, the domain needs at least three labels, because the zone above delegates its zone with an NS record.  The default is the guest itself under a reserved TLD, and otherwise the registrar of type.',
            },
            hostnames => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'The names under the domain that the recipes on it serve.  Each recipe hands its own over: see served_names in Provisioner::Recipe.  Not for an operator to write; configure an alias in the aliases of _global.',
            },
            address => {
                type        => 'string',
                format      => 'ipv4',
                description => 'The address that the A record of the domain names.  The default is main_ip, the address the guest was built with.  Set it for a guest that is reached through a port forward on a gateway.',
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

Returns how lexicon gets to the server that holds the zone of
C<$opts{domain}>, as these keys:

=over 4

=item * C<type>: the name of the lexicon provider.  This name also names the
environment variables of the provider and the shortcut installed for it.

=item * C<user>: the account, if the provider wants one.  Usually it is empty,
because most providers take only a token.

=item * C<key>: the token that lexicon authenticates with.

=item * C<key_file>: optional.  A file on the guest that holds the token, in
place of C<key>.

=item * C<opts>: flags that every lexicon command for this provider needs, as a
string.  Usually it is empty.

=item * C<zone>: optional.  The zone that the challenge of every name of this
domain goes into.  The hook gives it to lexicon in place of the name, so that
lexicon finds the zone without a query for a name that has no record yet.
Without it, lexicon finds the zone of each name itself.

=item * C<extra>: provider options other than the credential, as a list of
C<{ key =E<gt> ..., value =E<gt> ... }>.  Each one becomes
C<LEXICON_E<lt>TYPEE<gt>_E<lt>KEYE<gt>>.

=back

Where the guest holds the zone, it returns what
L<Provisioner::Recipe::pdns/lexicon_credentials> returns for the pdns of the
guest.  Where another guest does, it returns what
L<Provisioner::Recipe::pdns/client_credentials> returns for that guest.
Otherwise it returns C<configured_credentials>.

A registrar needs only a credential.  lexicon already knows where each of its
providers is, so there is no endpoint.  There are no flags, because the domain
is its own zone here.  C<--resolve-zone-name> spends live queries to find a
zone that is already known.

Dies as C<configured_credentials> does.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain};
    my $pdns   = Provisioner::Cookbook->load('pdns');

    if ( $self->serves_itself($domain) ) {
        my $server = Provisioner::Cookbook->host_of($domain) // $domain;
        return $pdns->lexicon_credentials( %{ Provisioner::Cookbook->domain_config($server)->{pdns} // {} }, domain => $domain );
    }

    my $guest = $self->delegated_to($domain);
    return $pdns->client_credentials( $guest, $domain ) if defined $guest;

    return $self->configured_credentials(%opts);
}

=head2 %credentials = $recipe->credentials_for(%opts)

C<lexicon_credentials> for C<$opts{domain}>, with the configuration of this
recipe that the domain has, or else the configuration of the guest that the
domain is layered onto.  It reads the configuration that the environment
names, from L<Provisioner::Cookbook>.

L<Provisioner::Recipe::letsencrypt> and L<Provisioner::Recipe::lexicon> ask
this, so that the hook and the shortcut render from one answer.

=cut

sub credentials_for {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain};
    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my $name   = $self->recipe_name;
    my $conf   = Provisioner::Cookbook->domain_config($domain)->{$name} // Provisioner::Cookbook->domain_config($server)->{$name} // {};

    return $self->lexicon_credentials( %{$conf}, domain => $domain );
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

    die "registrar has no type for $opts{domain}, and no server of this installation holds its zone.  Name the provider that holds the zone, as lexicon calls it, or name an authority.\n"
      unless $opts{type};

    return (
        type  => $opts{type},
        user  => $opts{user} // q{},
        key   => $opts{key}  // q{},
        opts  => q{},
        extra => [],
    );
}

=head2 $guest = $recipe->authority_of($domain)

Returns the guest whose pdns holds the zone of C<$domain>, or undef where the
registrar of C<type> holds it.  For a domain that is layered onto another
guest, that guest is the server of the domain.  The answer is the first of
these:

=over 4

=item * The C<authority> of this recipe for C<$domain>, or else for its server.

=item * The server, if C<$domain> is under a reserved TLD.

=item * undef.

=back

It reads the configuration that the environment names, from
L<Provisioner::Cookbook>, and not the module list.  The depsolver adds to that
list between C<required_recipes> and C<enrich>, so the two get different
answers from it.

=cut

sub authority_of {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my @where  = map { Provisioner::Cookbook->domain_config($_) } uniq( $domain, $server );

    foreach my $conf (@where) {
        my $authority = ( $conf->{ $self->recipe_name } // {} )->{authority};
        return Provisioner::Utils::dns_name($authority) if defined $authority;
    }

    return $server if Provisioner::Utils::reserved_tld($domain);
    return;
}

=head2 $bool = $recipe->serves_itself($domain)

True where the pdns of the server of C<$domain> holds its zone, as
C<authority_of> says.

=cut

sub serves_itself {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my $holder = $self->authority_of($domain);

    return ( defined $holder && $holder eq $server ) ? 1 : 0;
}

=head2 @recipes = $recipe->zone_server_for($domain, \@recipes, %walk)

Returns pdns where a guest of C<@recipes> holds its own zone and does not list
pdns, and an empty list otherwise.  The guest holds its own zone where its
recipes bring the registrar and C<serves_itself> is true.  Its recipes are
C<@recipes>, the recipes of the C<base> of C<%walk>, which every domain
inherits, and what C<recipes_with> in L<Provisioner::Cookbook> adds to both,
with C<%walk> as its C<%opts>.  Nothing adds pdns to such a guest, and
C<enrich> refuses it without one, so whatever writes the configuration of a
guest asks this.

=cut

sub zone_server_for {
    my ( $self, $domain, $recipes, %walk ) = @_;

    my @named = uniq( @$recipes, grep { !m/\A_/ } keys %{ $walk{base} // {} } );
    return if List::Util::any { $_ eq 'pdns' } @named;
    return unless List::Util::any { $_ eq $self->recipe_name } Provisioner::Cookbook->recipes_with( \@named, %walk, domain => $domain );
    return unless $self->serves_itself($domain);
    return 'pdns';
}

=head2 $guest = $recipe->delegated_to($domain)

Returns what C<authority_of> returns, where that is another guest than the
server of C<$domain>, and undef otherwise.

=cut

sub delegated_to {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my $holder = $self->authority_of($domain);

    return ( defined $holder && $holder ne $server ) ? $holder : undef;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

For a domain with an C<authority>, where this recipe holds the zone, the token
of the domain, which the authority issues.  See
L<Provisioner::Recipe::pdns/client_secret>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    my $guest = $self->delegated_to($domain);
    return () unless defined $guest;

    return Provisioner::Cookbook->load('pdns')->client_secret( $guest, Provisioner::Utils::dns_name($domain) );
}

=head2 %publication = $recipe->publication(%opts)

What this recipe publishes for C<$opts{domain}>, as options for its templates:
C<address>, C<domain_aliases>, C<own_nameserver>, and C<publish_records>, which
is true when there is an address to publish.  C<$opts{own_zone}> is true where
the domain holds its own zone.

The records are an C<A> record of the domain at C<address>, and a C<CNAME> for
each name in C<domain_aliases>: the aliases that the operator configured and
the C<hostnames> that the recipes handed over.  Where the domain holds its own
zone, they also include an C<A> record of C<own_nameserver>, which is C<ns1> of
the domain, at the same address.  The target of an C<NS> record must not be a
C<CNAME>.  F<scripts/publish_dns_records> writes them through the lexicon
shortcut of the domain, in the postrun.  It never deletes a record, and changes
only a record of ours that has the wrong content, so a rebuild from the same
configuration sends nothing.

The address goes up as it is, an RFC 1918 address of a fleet behind NAT
included: a zone that holds internal addresses for internal names is ordinary,
and it is the address that the client needs.  pdns writes C<ns1> into its own
zone at the address of the guest in the installation, and this recipe then
moves it to C<address>, where the glue in the zone above also points.  So a
resolver that asks the zone itself for its nameserver gets the address that
the glue gave it.  A zone that a registrar or another guest holds has
nameservers of its own, and gets no C<ns1>.

There is nothing to publish where the hypervisor allocates the address, and
leaves C<main_ip> empty when the makefile is written.

=cut

sub publication {
    my ( $self, %opts ) = @_;

    my $address = $opts{address} // $opts{main_ip};

    return (
        address         => $address,
        domain_aliases  => [ $self->domain_aliases(%opts) ],
        own_nameserver  => $opts{own_zone} ? "ns1.$opts{domain}" : undef,
        publish_records => $address        ? 1                   : 0,
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds what C<publication> says this recipe publishes.

With an C<authority> on another guest, adds C<authority>, C<authority_address>,
its address, C<routing_domains>, the zones that the guest asks it for, as
systemd-resolved spells them, and C<fleet_anchor>, which is true where the
authority is under a reserved TLD.  An C<authority> that names the guest itself
is dropped.

Where a server of this installation holds the zone, the guest itself or
another guest, and the domain is not under a reserved TLD, also adds what the
zone above needs to delegate the zone: C<upstream>, the credentials of the
registrar of the zone above, C<parent>, the name above the domain,
C<nameserver>, the name that the C<NS> record names, and C<glue>, the address
of the nameserver where its name is inside the zone, as C<ns1> of a guest that
holds its own zone is.  The nameserver is the authority, or C<ns1> of the
server of the domain, which is the name that F<pdns.zone.tt> gives its own
nameserver.  The address of C<ns1> is the address of the A record of the
domain, as C<publication> says.

Where the registrar of C<type> holds the zone, dies when there is no C<type>.
Where a server of this installation holds the zone, dies when that server runs
no pdns, as C<needs_recipe> in L<Provisioner::Cookbook> says, and outside a
reserved TLD, when the domain has fewer than three labels.  Dies when the
installation gave an address to neither another guest that holds the zone, nor
a nameserver that needs glue.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain};
    my $server = Provisioner::Cookbook->host_of($domain) // $domain;
    my $holder = defined $opts{authority} ? Provisioner::Utils::dns_name( $opts{authority} ) : $self->authority_of($domain);
    delete $opts{authority};
    unless ( defined $holder ) {
        $self->configured_credentials(%opts);
        return ( %opts, $self->publication(%opts) );
    }

    my $delegated = !Provisioner::Utils::reserved_tld($domain);
    die "$domain names $holder as the authority of its registrar, but has fewer than three labels.  Its zone is delegated with an NS record in the zone of a registered domain, and a registered domain itself needs glue at the registry, which most registrars have no API for.\n"
      if $delegated && ( $domain =~ tr/.// ) < 2;
    Provisioner::Cookbook->needs_recipe( $domain, $holder, 'pdns', 'the authority of its registrar' );

    my $address = ( $opts{ipmap} // {} )->{$holder};
    if ( $holder ne $server ) {
        die "$domain names $holder as the authority of its registrar, and the installation gave $holder no address to ask it at.  Give it an address of the pool.\n"
          unless $address;

        $opts{authority}         = $holder;
        $opts{authority_address} = $address;
        $opts{routing_domains}   = join( q{ }, map { "~$_" } $domain, ( $self->serves_itself($holder) ? $holder : () ) );
        $opts{fleet_anchor}      = Provisioner::Utils::reserved_tld($holder) ? 1 : 0;
    }
    my %publication = $self->publication( %opts, own_zone => $holder eq $domain );
    return ( %opts, %publication ) unless $delegated;

    # The guest itself answers at the address that its A record publishes.
    my $nameserver = $holder eq $server ? "ns1.$server"         : $holder;
    my $glue       = $holder eq $server ? $publication{address} : $address;
    my $in_zone    = $nameserver eq $domain || $nameserver =~ m/[.]\Q$domain\E\z/;
    die "$domain is delegated to $nameserver, which is inside its zone, and the installation gave $holder no address to publish for it.  Give it an address of the pool.\n"
      if $in_zone && !$glue;

    $opts{upstream}   = { $self->configured_credentials( %opts, domain => $domain ) };
    $opts{parent}     = $domain =~ s/\A[^.]+[.]//r;
    $opts{nameserver} = $nameserver;
    $opts{glue}       = $in_zone ? $glue : undef;

    return ( %opts, %publication );
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

Returns lexicon, which publishes the records, and which an operator edits the
zone with.  It does not return pdns where the guest holds its own zone.  The
configuration of the guest names pdns there, as it does on another guest that
holds a zone.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    return (
        lexicon => sub { return () },
    );
}

1;
