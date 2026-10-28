package Provisioner::Recipe::registrar;

#ABSTRACT: Which server holds the zone of a domain, how lexicon reaches it, and its records.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Cpanel::JSON::XS();
use File::Copy();
use File::Slurper::Temp();
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

=head2 Accounts, and the zones that they hold

C<accounts> names each registrar account of this installation once, with the
C<type>, C<user> and C<key> of its registrar, and lists the zones that it
holds:

    _base:
        registrar:
            accounts:
                ours:
                    type: easydns
                    user: "secret:registrar/ours/username"
                    key:  "secret:registrar/ours/password"
                    zones: [ ours.example, other.example ]
                customer:
                    type: route53
                    key:  "secret:registrar/customer/token"
                    zones: [ customer.example ]

A domain in one of these zones writes its own records with that account: the
domain is the zone, or a name under it.  So an installation whose zones are at
several accounts, or behind tokens scoped to one domain each, lists each zone
once here, and a domain needs no C<type>, C<user> or C<key> of its own.  The
account comes before the C<type>, C<user> and C<key> of the registrar, which
are for a domain in a zone that no account lists.  Where two listed zones hold
the domain, the longer one does.

A served name in one of these zones, such as a public name of
L<Provisioner::Recipe::nginx>, is published and certified like a name of the
domain.  The guest publishes it in its zone as a C<CNAME> of the domain, as it
publishes the aliases of the domain.  The apex of the zone is the exception,
because the apex holds the C<SOA> and C<NS> records, and a C<CNAME> cannot
stand beside them.  The apex gets an C<A> record at the address of the domain.  The
hook of L<Provisioner::Recipe::letsencrypt> writes the challenge of each such
name in its zone too.  The guest gets a lexicon shortcut,
F</opt/lexicon/zones/ZONE>, only for each zone that one of its names is in.  So
a guest holds no credential of a zone that it does not use.

A name in the zone of the domain is the business of the domain, even where an
account lists a zone that holds it as well.  It goes through the shortcut of the
domain, with the credentials of the domain, which can be those of that account.
Where two zones hold a name, the longer one does.  A zone is at one registrar, so the recipe refuses a zone that
two accounts list.

=head2 Zones that a pdns guest holds

An account can name an C<authority> in place of C<type>, C<user> and C<key>:
a guest of this installation that runs pdns.  Its zones are zones that the
owner delegated to our nameservers at their own registrar, so that pdns
answers for them:

    _base:
        registrar:
            accounts:
                ours:
                    authority: ns.ours.example
                    zones: [ customer.example ]

The authority builds each of these zones, with an C<SOA> record and an C<NS>
record that name its C<ns1>, and an C<NS> record for each of the
C<nameservers> of C<_global>.  A rebuild keeps a zone that its database holds
already.  See L<Provisioner::Recipe::pdns/Zones that it holds for accounts>.

A guest that serves a name in such a zone writes it as it writes a name of any
account, through F</opt/lexicon/zones/ZONE>.  The shortcut reaches the API
proxy of the authority with a token that the authority grants it.  See
C<grants>.  The token can write the C<A> and C<CNAME> records of the names of that
guest in the zone, and the challenges of those names, and nothing else.  So
several guests can serve names in one zone, and none of them can change the
names of another.  F<bin/destroy> removes the tokens of a guest, and leaves
the zones.

The owner delegates the zone before its names are built, because the CA asks
the delegated nameservers for each challenge.  F<bin/check_delegation> says
whether the delegation is in place.  F<docs/PUBLIC_NAMES.md> has the whole
procedure.

Write these accounts in C<_base>.  The authority reads them from its own
configuration, and a domain sees them in its own.

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
            accounts => {
                type                 => 'object',
                default              => {},
                additionalProperties => {
                    type                 => 'object',
                    oneOf                => [ { required => ['type'] }, { required => ['authority'] } ],
                    additionalProperties => 0,
                    properties           => {
                        authority => {
                            type        => 'string',
                            format      => 'hostname',
                            description => 'A guest of this installation that runs pdns, in place of type, user and key.  It holds the zones of this account, and builds each of them.  See "Zones that a pdns guest holds".',
                        },
                        type  => { type => 'string', description => 'The provider of this account, as lexicon calls it.' },
                        user  => { type => 'string', default     => q{}, description => 'The account, where the provider wants one.' },
                        key   => { type => 'string', default     => q{}, 'x-secret'  => 1, description => 'The token of this account, as a secret: reference.' },
                        zones => {
                            type        => 'array',
                            items       => { type => 'string', format => 'hostname' },
                            default     => [],
                            description => 'The zones that this account holds, other than the zone of the domain.  A served name in one of them is published there and certified.',
                        },
                    },
                },
                description => 'The registrar accounts of this installation, each under a name of your choice, with its type, user and key or its authority, and the zones other than the zone of the domain that it holds.  See "Accounts, and the zones that they hold".',
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
L<Provisioner::Recipe::pdns/socket_credentials> returns for the pdns of the
guest.  Where another guest does, it returns what
L<Provisioner::Recipe::pdns/client_credentials> returns for that guest.
Otherwise it returns C<domain_credentials>.

A registrar needs only a credential.  lexicon already knows where each of its
providers is, so there is no endpoint.  There are no flags, because the domain
is its own zone here.  C<--resolve-zone-name> spends live queries to find a
zone that is already known.

Dies as C<domain_credentials> does.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain};
    my $pdns   = Provisioner::Cookbook->load('pdns');

    return $pdns->socket_credentials( domain => $domain ) if $self->serves_itself($domain);

    my $guest = $self->delegated_to($domain);
    return $pdns->client_credentials( $guest, $domain ) if defined $guest;

    return $self->domain_credentials(%opts);
}

=head2 %credentials = $recipe->domain_credentials(%opts)

The credentials with which C<$opts{domain}> writes its own zone at a
registrar.  They are those of the account whose zone is the domain or holds
it, as C<account_for> finds it.  Where no account lists such a zone, they are
C<configured_credentials>.  Dies as C<configured_credentials> does.

=cut

sub domain_credentials ( $self, %opts ) {
    my ( $zone, $account ) = $self->account_for( $opts{domain}, \%opts );
    return $self->zone_credentials( $zone, $account ) if defined $zone;
    return $self->configured_credentials(%opts);
}

=head2 %credentials = $recipe->parent_credentials(%opts)

The credentials with which C<$opts{domain}> writes the zone above its own,
where the C<NS> record that delegates it goes.  They are those of the account
whose zone holds the domain and is not the domain itself.  Where no account
lists such a zone, they are C<configured_credentials>.

=cut

sub parent_credentials ( $self, %opts ) {
    my ( $zone, $account ) = $self->account_for( $opts{domain}, \%opts, above => 1 );
    return $self->zone_credentials( $zone, $account ) if defined $zone;
    return $self->configured_credentials(%opts);
}

=head2 ($zone, \%account) = $recipe->account_for($domain, \%conf, above => $bool)

The zone of C<$conf{accounts}> that is C<$domain> or holds it, and what
C<account_zones> maps that zone to.  Where two zones hold the domain, the longer
one does.  With C<above> true, a zone that is the domain itself does not
count.  Returns an empty list when no account lists such a zone.

=cut

sub account_for ( $self, $domain, $conf, %how ) {
    my %zones  = $self->account_zones(%$conf);
    my $name   = Provisioner::Utils::dns_name($domain);
    my @holds  = grep { ( !$how{above} && $name eq $_ ) || $name =~ m/[.]\Q$_\E\z/ } keys %zones;
    my ($zone) = $self->longest_first(@holds) or return;
    return ( $zone, $zones{$zone} );
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

    return $self->lexicon_credentials( %{ $self->configuration_of( $opts{domain} ) }, domain => $opts{domain} );
}

=head2 \%conf = $recipe->configuration_of($domain)

The configuration of this recipe that C<$domain> has, or else the configuration
of the guest that C<$domain> is layered onto, from L<Provisioner::Cookbook>.

=cut

sub configuration_of ( $self, $domain ) {
    my $server = Provisioner::Cookbook->machine_of($domain);
    my $name   = $self->recipe_name;
    return Provisioner::Cookbook->domain_config($domain)->{$name} // Provisioner::Cookbook->domain_config($server)->{$name} // {};
}

=head2 %credentials = $recipe->configured_credentials(%opts)

Returns C<type>, C<user> and C<key> as the operator configured them, with an
empty string for an unset C<user> or C<key>.  C<opts> is empty and C<extra> is
an empty list.  Dies when there is no C<type>.

C<domain_credentials> and C<parent_credentials> fall back to this, where no
account lists the zone.

=cut

sub configured_credentials {
    my ( $self, %opts ) = @_;

    die "registrar has no type for $opts{domain}, and no server of this installation holds its zone.  List its zone under an account of accounts, name the provider that holds the zone, as lexicon calls it, or name an authority.\n"
      unless $opts{type};

    return (
        type  => $opts{type},
        user  => $opts{user} // q{},
        key   => $opts{key}  // q{},
        opts  => q{},
        extra => [],
    );
}

=head2 $zone = $recipe->zone_of($name, $domain, \%zones)

The zone of an account that holds C<$name>, or undef where the zone of
C<$domain> holds it, or where no account lists a zone that does.  So it
answers whether a name that the guest serves goes through the zone of the
domain, or through the zone of an account and its credentials.  See
L</Accounts, and the zones that they hold>.

L<Provisioner::Recipe::nginx> asks it whether it can certify a public name.
L<Provisioner::Recipe::letsencrypt> asks it which shortcut the hook uses for
each name of the certificate.  C<zone_aliases> asks it which names the zone of
the domain leaves out.

A name in the zone of C<$domain> has none, because it is the business of the
domain.  Where two zones hold the name, the longer one does.  C<%zones> is what
C<account_zones> returns.  Where it is undef, this reads it for C<$domain> from
L<Provisioner::Cookbook>, as C<configured_zones> does.

=cut

sub zone_of ( $self, $name, $domain, $zones = undef ) {
    my $in = sub ($zone) { return lc $name eq lc $zone || $name =~ m/[.]\Q$zone\E\z/i };
    return if $in->($domain);

    $zones //= { $self->configured_zones($domain) };
    my ($zone) = $self->longest_first( grep { $in->($_) } keys %$zones );
    return $zone;
}

=head2 @zones = $recipe->longest_first(@zones)

C<@zones>, the longer first, and in order of the name where two are as long.
A zone inside another is longer, so it comes first, as C<zone_of> decides.

=cut

sub longest_first ( $, @zones ) {
    my @sorted = sort { -( length $a <=> length $b ) || $a cmp $b } @zones;
    return @sorted;
}

=head2 %zones = $recipe->account_zones(%conf)

Maps each zone that an account of C<$conf{accounts}> lists to the C<type>,
C<user> and C<key> of that account, or to its C<authority>.  Dies on a zone
that two accounts list.  Each zone is in lower case, with no trailing dot.

=cut

sub account_zones ( $, %conf ) {
    my %accounts = %{ $conf{accounts} // {} };

    my ( %zones, %listed_by );
    foreach my $name ( sort keys %accounts ) {
        foreach my $zone ( map { Provisioner::Utils::dns_name($_) } @{ $accounts{$name}{zones} // [] } ) {
            die "registrar: the accounts $listed_by{$zone} and $name both list the zone $zone.  A zone is at one registrar, so list it under one account.\n"
              if exists $listed_by{$zone};
            $listed_by{$zone} = $name;
            $zones{$zone}     = { map { $_ => $accounts{$name}{$_} } grep { exists $accounts{$name}{$_} } qw{type user key authority} };
        }
    }
    return %zones;
}

=head2 %zones = $recipe->configured_zones($domain)

C<account_zones> of the configuration that C<configuration_of> reads for
C<$domain>.

=cut

sub configured_zones ( $self, $domain ) {
    return $self->account_zones( %{ $self->configuration_of($domain) } );
}

=head2 %credentials = $recipe->zone_credentials($zone, \%account)

How lexicon writes C<$zone>, for C<%account>, which is what C<account_zones>
maps C<$zone> to.  For an account with an C<authority>, it is what
L<Provisioner::Recipe::pdns/client_credentials> returns for that guest.
Otherwise it is C<configured_credentials>.

=cut

sub zone_credentials ( $self, $zone, $account ) {
    return Provisioner::Cookbook->load('pdns')->client_credentials( Provisioner::Utils::dns_name( $account->{authority} ), $zone ) if defined $account->{authority};
    return $self->configured_credentials( %$account, domain => $zone );
}

=head2 @aliases = $recipe->zone_aliases(%opts)

The names that the zone of C<$opts{domain}> holds as C<CNAME> records of the
domain.

C<domain_aliases> gives every name that the guest serves besides the domain:
the aliases of C<_global>, and the C<hostnames> that the recipes on it hand
over.  Most of them are under the domain.  A public name of
L<Provisioner::Recipe::nginx> in a zone that an account lists is not.  It
belongs to that zone, and C<publication> gives it an C<A> record there,
through the shortcut of that zone.  So this returns C<domain_aliases> less
each name that C<zone_of> places in a zone of an account, and less each name
of C<zone_address_names>, which holds an C<A> record.

Each writer of the zone of the domain asks this, so that none of them writes
such a name there: C<publication>, the zone file of
L<Provisioner::Recipe::pdns>, and F<bin/ipmap2zones>.  pdns refuses a zone file
with a record outside its zone as invalid, so one such name breaks the whole
zone.

C<$opts{zones}> is what C<account_zones> returns, where the caller has it.
Otherwise this reads it for the domain from L<Provisioner::Cookbook>.

=cut

sub zone_aliases ( $self, %opts ) {
    my $zones     = $opts{zones} // { $self->configured_zones( $opts{domain} ) };
    my %addressed = map { $_ => 1 } $self->zone_address_names( %opts, zones => $zones );
    return grep { !$addressed{$_} && !defined $self->zone_of( $_, $opts{domain}, $zones ) } $self->domain_aliases(%opts);
}

=head2 @names = $recipe->zone_address_names(%opts)

The names that the zone of C<$opts{domain}> holds as C<A> records at the
address of the domain, and not as C<CNAME> records: the C<addressed_names> of
each recipe in C<$opts{modules}>, as L<Provisioner::Recipe> says, less each
name that C<zone_of> places in a zone of an account.  Sorted.

The writers of the zone that ask C<zone_aliases> ask this too.
C<$opts{zones}> is as C<zone_aliases> says.

=cut

sub zone_address_names ( $self, %opts ) {
    my $zones = $opts{zones} // { $self->configured_zones( $opts{domain} ) };
    my @names = map { Provisioner::Cookbook->load($_)->addressed_names( domain => $opts{domain} ) } @{ $opts{modules} // [] };
    return grep { !defined $self->zone_of( $_, $opts{domain}, $zones ) } sort( uniq(@names) );
}

=head2 @records = $recipe->zone_records(%opts)

The records other than names that the zone of C<$opts{domain}> holds: the
C<dns_records> of each recipe in C<$opts{modules}>, as L<Provisioner::Recipe>
says, less each record that C<zone_of> places in a zone of an account.  Each
comes once, sorted by type, name and content.

The writers of the zone that ask C<zone_aliases> ask this too.
C<$opts{zones}> is as C<zone_aliases> says.

=cut

sub zone_records ( $self, %opts ) {
    my $zones   = $opts{zones} // { $self->configured_zones( $opts{domain} ) };
    my @records = map { Provisioner::Cookbook->load($_)->dns_records( domain => $opts{domain} ) } @{ $opts{modules} // [] };
    my %seen;
    my @ours   = grep { !$seen{"$_->{type} $_->{name} $_->{content}"}++ && !defined $self->zone_of( $_->{name}, $opts{domain}, $zones ) } @records;
    my @sorted = sort { $a->{type} cmp $b->{type} || $a->{name} cmp $b->{name} || $a->{content} cmp $b->{content} } @ours;
    return @sorted;
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

    my $server = Provisioner::Cookbook->machine_of($domain);
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

    my $server = Provisioner::Cookbook->machine_of($domain);
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

    my $server = Provisioner::Cookbook->machine_of($domain);
    my $holder = $self->authority_of($domain);

    return ( defined $holder && $holder ne $server ) ? $holder : undef;
}

=head2 @grants = $recipe->grants($domain, %opts)

What the pdns guests that serve C<$domain> grant it, as C<grants> in
L<Provisioner::Recipe> says.  See L<Provisioner::Recipe::pdns/issue_grant>.

For a domain with an C<authority>, where this recipe holds the zone, the zone
of the domain and its token, on the guest that C<delegated_to> names.  And for
each guest that an account names the C<authority> of a zone, the tokens of the
domain in those zones, as one grant with C<zones>.  See
L</Zones that a pdns guest holds>.  This names every such zone, so that
C<bin/destroy> asks about each of them.  C<grant_terms> leaves out a zone that
holds no served name of the domain.

=cut

sub grants {
    my ( $self, $domain, %opts ) = @_;

    my $client = Provisioner::Utils::dns_name($domain);
    my @grants;

    my $own = $self->delegated_to($domain);
    push( @grants, { recipe => 'pdns', guest => $own, client => $client } ) if defined $own;

    my %zones = $self->configured_zones($domain);
    my %of;
    foreach my $zone ( sort keys %zones ) {
        push( @{ $of{ Provisioner::Utils::dns_name( $zones{$zone}{authority} // next ) } }, $zone );
    }
    push( @grants, map { +{ recipe => 'pdns', guest => $_, client => $client, zones => $of{$_} } } sort keys %of );

    return @grants;
}

=head2 %terms = $recipe->grant_terms($grant, %opts)

For a grant with C<zones>, C<names>: each of those zones that holds a served
name of the client, mapped to those names.  The served names are
C<domain_aliases> of C<%opts>, where C<hostnames> is what the recipes on the
domain handed over.  Otherwise nothing.

=cut

sub grant_terms {
    my ( $self, $grant, %opts ) = @_;
    return () unless $grant->{zones};

    my $domain = $grant->{client};
    my %zones  = $self->configured_zones($domain);
    my %wanted = map { $_ => 1 } @{ $grant->{zones} };

    my %names;
    foreach my $name ( $self->domain_aliases( %opts, domain => $domain ) ) {
        my $zone = $self->zone_of( $name, $domain, \%zones ) // next;
        push( @{ $names{$zone} }, lc $name ) if $wanted{$zone};
    }
    return ( names => \%names );
}

=head2 %publication = $recipe->publication(%opts)

What this recipe publishes for C<$opts{domain}>, as options for its templates:
C<address>, C<domain_aliases>, C<address_names>, C<zone_records>,
C<own_nameserver>, C<zone_cnames>, C<zone_apexes>, C<zone_access>, and
C<publish_records>, which is true when there is an address to publish.

These three are for the served names in a zone of an account.  C<zone_cnames>
maps each such zone to its names other than its apex, and each gets a C<CNAME>
of the domain in that zone.  C<zone_apexes> lists each such zone whose apex is a
served name, and the apex gets an C<A> record at C<address>.  C<zone_access>
maps every such zone to the credentials of its account, as
C<zone_credentials> returns them.  See L</Accounts, and the zones that they
hold>.  C<$opts{own_zone}> is true where the domain holds its own zone.

The records are an C<A> record of the domain at C<address>, and a C<CNAME> for
each name in C<domain_aliases>: the aliases that the operator configured and
the C<hostnames> that the recipes handed over.  The exceptions are the names
of C<address_names>, which C<zone_address_names> gives, such as the target of
an C<MX>.  Each gets an C<A> record at the address.  The records also include
C<zone_records>, such as the C<MX> itself, which F<registrar-records.json>
carries to the publisher.  Where the domain holds its own
zone, they also include an C<A> record of C<own_nameserver>, which is C<ns1> of
the domain, at the same address.  The target of an C<NS> record must not be a
C<CNAME> either.  F<scripts/publish_dns_records> writes them through the lexicon
shortcut of the domain, in the postrun.  It changes only a record of ours that
has the wrong content, so a rebuild from the same configuration sends nothing.
It deletes one kind of record only: a C<CNAME> of the domain at a name that
now holds an C<A> record.

The address goes up as it is, an RFC 1918 address of a fleet behind NAT
included: a zone that holds internal addresses for internal names is ordinary,
and it is the address that the client needs.  pdns writes C<ns1> into its own
zone at the address of the guest in the installation, and this recipe then
moves it to C<address>, where the glue in the zone above also points.  So a
resolver that asks the zone itself for its nameserver gets the address that
the glue gave it.  A zone that a registrar or another guest holds has
nameservers of its own, and gets no C<ns1>.

On a hypervisor that allocates the address, C<bin/provision> reserves the
guest first, so C<main_ip> is that address when the makefile is written.  See
C<reserve_guest> in L<Trog::HV>.  There is nothing to publish where the guest
has no address yet, as on a backend that cannot reserve, or in a run of
F<bin/new_config> without C<--reserve>.

=cut

sub publication {
    my ( $self, %opts ) = @_;

    my $address = $opts{address} // $opts{main_ip};
    my $zones   = { $self->account_zones(%opts) };

    my ( %zone_cnames, %zone_apexes );
    foreach my $name ( $self->domain_aliases(%opts) ) {
        my $zone = $self->zone_of( $name, $opts{domain}, $zones ) // next;
        if ( lc $name eq lc $zone ) { $zone_apexes{$zone} = 1 }
        else                        { push( @{ $zone_cnames{$zone} }, $name ) }
    }
    my %zone_access = map { $_ => { $self->zone_credentials( $_, $zones->{$_} ) } } keys %zone_cnames, keys %zone_apexes;

    return (
        address         => $address,
        domain_aliases  => [ $self->zone_aliases( %opts, zones => $zones ) ],
        address_names   => [ $self->zone_address_names( %opts, zones => $zones ) ],
        zone_records    => [ $self->zone_records( %opts, zones => $zones ) ],
        zone_cnames     => \%zone_cnames,
        zone_apexes     => [ sort keys %zone_apexes ],
        zone_access     => \%zone_access,
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
    my $server = Provisioner::Cookbook->machine_of($domain);
    my $holder = defined $opts{authority} ? Provisioner::Utils::dns_name( $opts{authority} ) : $self->authority_of($domain);
    delete $opts{authority};
    unless ( defined $holder ) {
        $self->domain_credentials(%opts);
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

    $opts{upstream}   = { $self->parent_credentials( %opts, domain => $domain ) };
    $opts{parent}     = $domain =~ s/\A[^.]+[.]//r;
    $opts{nameserver} = $nameserver;
    $opts{glue}       = $in_zone ? $glue : undef;

    return ( %opts, %publication );
}

=head2 @written = $recipe->generate_files($output_dir, %vars)

Writes the templates, and the C<zone_records> as F<registrar-records.json>
where there are records to publish.  Also the certificate of the fleet
authority as F<registrar-anchor.crt> where C<enrich> sets C<fleet_anchor>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated(%vars);

    if ( $opts{publish_records} && @{ $opts{zone_records} } ) {
        my $encoder = Cpanel::JSON::XS->new->canonical->pretty;
        File::Slurper::Temp::write_binary( "$output_dir/registrar-records.json", $encoder->encode( $opts{zone_records} ) );
        push( @written, 'registrar-records.json' );
    }
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
        'registrar.zones.tt'    => 'registrar-zones.sh',
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
