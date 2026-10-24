package Provisioner::Recipe::pdns;

#ABSTRACT: Set up the PowerDNS resolver and install DNS records.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::pdns

=head2 SYNOPSIS

    somedomain:
        pdns:
            extra_records: zonefile_fragment.txt

=head2 DESCRIPTION

Sets up the PowerDNS authoritative server and recursor, and installs a set of
records for the recipes of the domain.  templates/files/pdns.zone.tt lists the
records.

The purpose is simple DNS delegation of subdomains to provisioned machines.

The server uses the sqlite backend.

C<extra_records> names one plain text file that holds a zonefile fragment.  The
recipe appends it to the zone.  A relative path is relative to the directory of
the domain in the data source.

The recursor lets you point a resolver at this guest for fast answers.  It also
reduces the DNS rate limiting that RBLs apply.

=head2 Zones of other guests

A guest can name this guest as the C<authority> of its registrar.  See
L<Provisioner::Recipe::registrar>.  Then this guest holds a zone of the name of
that guest, and that guest writes its records here, through the API proxy
below.  C<bin/provision> makes the zone when it builds that guest, with this
domain as its nameserver, and deletes the zone that a build before it made.
See C<issue_grant>.  The recursor of this guest forwards the zone to the
authoritative server, so that the CA of this guest finds the challenges of that
guest, wherever its name is.  A build of this guest forwards each zone that
its database holds again.

The server answers on port 53 of the address of the guest, as well as on
loopback, because the zone above names this domain as the nameserver of each
of those zones.  It answers only for the zones that it holds, and refuses
everything else.  The recursor stays on loopback.

=head2 Zones that it holds for accounts

An account of L<Provisioner::Recipe::registrar> can name this guest as the
C<authority> of its zones.  See
L<Provisioner::Recipe::registrar/Zones that a pdns guest holds>.  This guest
builds each of those zones, as it builds its own: a zone file with an C<SOA>
and C<NS> records, loaded only into a database that does not hold the zone yet.
So a rebuild keeps the records that the guests of the zone wrote.  The
recursor forwards each zone here, with a negative trust anchor, as it does the
zone of the domain.  A domain layered onto this guest does not build them
again.

Unlike a zone of another guest, no build of a guest replaces such a zone,
because several guests can serve names in it.  Each of them gets a token of
its own from C<issue_grant>.

=head2 The API proxy

This guest opens its API to other guests through L<PowerDNS::API::ACL>.  The API itself listens only on a unix socket on
the guest, and its one key can rewrite every zone on the guest.

A client presents a token of its own as its API key.  A grant lets a token read
or write the records of one name, or every name under a name, in one zone, or
create and delete one zone.  The proxy checks each request against the grants,
and passes an allowed one to pdns with the real key.  So a guest can publish
its own records and nothing else.

The API answers at C<dnsapi.$domain>, over TLS.  That name is a served name of
this recipe, so it gets a record and a certificate as every served name does.
Where the guest runs L<Provisioner::Recipe::acmeca>, the vhost also passes
C</acme/> to that CA, for the guests that name this one as their authority.
See L<Provisioner::Recipe::acmeca/Or on the authority, for the guests that name it>.
The vhost answers only the addresses that this installation gives its guests,
the addresses of this machine, the guest itself, and the networks in
C<api_allow>.  The addresses of the guests are the C<guests> bin of the
C<ip_pool> of C<_global>, whole, so that a guest that is built after this one
gets in, and each address
that the installation already gave out.

Starman runs the proxy as the C<pdns> user.  pdns creates its API socket with
its umask, which leaves the group no write, and a client needs to write to a
socket to connect.  So the guest gets a drop-in that sets the umask of pdns to
C<0002>.  Other files that pdns creates become writable by the C<pdns> group
too, which this recipe already makes of everything under
F</var/spool/powerdns>.  The tokens are in F</var/lib/pdns-acl/acl.db>.

A guest that names this guest as its authority gets a token from this guest
when it is built.  C<bin/provision> runs C<pdns-acl> here over ssh, and puts the
token on the other guest.  See C<issue_grant>.  The token is labeled with the
name that it writes, and a new build of that guest replaces it.  So C<pdns-acl
token list> shows each of them, and C<pdns-acl token remove> revokes one.
C<bin/destroy> of that guest removes the token and the zone.

Make any other token on the guest with C<pdns-acl>, as the C<pdns> user so that
the database stays its own.  Name the perl that the perl recipe built:
C<pdns-acl> starts with C</usr/bin/env perl>, and the PATH of C<sudo> finds the
system perl, which has none of the modules.

    sudo -u pdns /opt/perl5/current/bin/perl /opt/perl5/current/bin/pdns-acl \
        token add web1 --zone lab.example.net. --name web1.lab.example.net. --write

=cut

use Text::Xslate;
use Net::IP;
use File::Slurper;
use Crypt::PRNG();

use Data::Validate::Domain();
use List::Util  qw{any uniq};
use Time::HiRes qw{time};

use Provisioner::Cookbook();
use Provisioner::IPPool();
use Provisioner::Utils();
use Provisioner::Vars();

# The API socket as the host sees it.  pdns binds /api.sock inside its chroot,
# which is this path from outside.
our $API_SOCKET = '/var/spool/powerdns/api.sock';

# The key of the API on the guest, which bin/provision puts there from the
# store.  See guest_secrets.
our $API_KEY_FILE = '/etc/powerdns/api-key';

sub rate_limits {

    # A resolver asks over udp and asks often, and a recursor in front of this
    # server asks for everybody behind it.  The limit is high enough that only a
    # reflection flood reaches it.
    #
    # tcp is limited too, because a zone transfer and a large answer use it.
    # An unlimited protocol is the one that a flood uses.
    return ( 53 => 4096, '53/udp' => 4096 );
}

=head2 @claims = $recipe->listens()

The authoritative server on 2500, on 127.0.0.1, where the recursor on 53 sends
the zones that this guest serves.  C<rate_limits> names 53.

=cut

sub listens {
    return qw{127.0.0.1:2500 127.0.0.1:2500/udp};
}

=head2 @names = $recipe->subdomains()

C<dnsapi.$domain>, where the API proxy answers.

=cut

sub subdomains {
    return qw{dnsapi};
}

=head2 %required = $recipe->required_recipes(%opts)

Adds C<nostubresolver> and C<lexicon>, C<perl>, which installs the API proxy,
and C<nginx>, which serves it.

L<Provisioner::Recipe::lexicon> is the client that writes records into the zone
of this server.

This server is the only thing that answers for the zone of the guest, and the
systemd stub resolver does not ask it.  lexicon looks up the zone through the
system resolver for C<--resolve-zone-name>, and step-ca validates dns-01 through
it.  So on the stub, the guest cannot resolve its own name.

A guest that holds its own zone lists this recipe, and
L<Provisioner::Recipe::registrar> refuses one that does not.  See
L<Provisioner::Recipe::registrar/authority_of>.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    my @served = $self->served_names(%opts);
    return (
        nostubresolver => sub { return () },
        lexicon        => sub { return () },

        # The perl target runs after this fragment, so the proxy starts in the
        # postrun, when Starman and the proxy are installed.
        perl  => sub { return ( cpan_deps => [ { install => [ 'Starman', 'PowerDNS::API::ACL~>= 0.002' ] } ] ) },
        nginx => sub { return ( sites     => [@served] ) },
    );
}

sub args {
    return (
        type       => 'object',
        properties => {
            api_key => {
                type        => 'string',
                'x-secret'  => 1,
                description =>
                  'The credential everything on this guest presents to talk to the API on its loopback socket, such as lexicon writing an _acme-challenge record.  Made when nobody sets one, because it is a secret nobody chose rather than a decision an operator has to make; a secret: reference is how you set one deliberately.  The first build keeps it in the store, at secret:pdns/GUEST-api-key/password, and every later build reads it from there, so a later change goes in the store.  It belongs to the server, set on the domain of the guest, and a domain layered onto another guest presents that key.',
            },
            extra_records => { type => 'string' },

            api_allow => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'More addresses or networks that may reach the API proxy, beside the guests of this installation, the addresses of this machine and the guest itself.  For a guest that reaches it through NAT, name the address it arrives from.',
            },
            api_ipv6 => { type => 'boolean', default => 1, description => 'Whether the vhost of the API proxy listens on IPv6 as well.' },

            # The repo.powerdns.com release train to install from.  A release,
            # not auth-master, which is the development branch.  The API is on a
            # unix socket, and lexicon-pdns-af-unix.patch lets lexicon use it.
            # webserver-address takes a socket path only from PowerDNS 5.0.0.
            # On 4.9, pdns_server does not start and says "Unable to convert
            # presentation address".
            repo_branch => {
                type    => 'string', default => 'auth-51',
                pattern => '^auth-[0-9]+$'
            },

            # Zones to forward to another resolver, as zone => address.
            forward_zones => { type => 'object', default => {} },
        },
    );
}

=head2 %credentials = $recipe->socket_credentials(%opts)

The credentials for the API on the unix socket of this server.  Anything on
this guest writes a record into the zone of this server through that API.  See
L<Provisioner::Recipe::registrar/lexicon_credentials> for the keys that come
back.

C<opts> is C<--resolve-zone-name>, because lexicon reduces a name to its
registrable form with tldextract before it asks for a zone.  A reserved TLD is
not a public suffix, so without the flag lexicon asks for the zone "test" and
gets a 404.

=cut

sub socket_credentials {
    return (
        type     => 'powerdns',
        user     => q{},
        key      => q{},
        key_file => $API_KEY_FILE,
        opts     => '--resolve-zone-name',
        extra    => [ { key => 'PDNS_SERVER', value => $API_SOCKET } ],
    );
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain)

The key of the API, at C<$API_KEY_FILE>, as C<guest_secrets> in
L<Provisioner::Recipe> says.  The global fragment writes it into the
configuration of pdns, and the proxy, the lexicon shortcut and the dehydrated
hook read it from there.  So every client presents the key that the server
runs with, and the key is not in the payload.

The server belongs to a guest, not to a domain.  The reference names the
guest that L<Provisioner::Cookbook/host_of> finds for C<$domain>, so each
domain on one guest gets the same key.  The key is the C<api_key> of that
guest if an operator set one, and random if not.  The store keeps whichever the
first build made.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    my $server     = Provisioner::Cookbook->host_of($domain) // $domain;
    my $configured = Provisioner::Cookbook->domain_config($server)->{ $self->recipe_name }{api_key};

    return (
        $API_KEY_FILE => {
            ref      => "secret:pdns/$server-api-key/password",
            generate => sub { return $configured || Crypt::PRNG::random_bytes_hex(32) },
            owner    => 'root:pdns',
            mode     => '0640',
        },
    );
}

=head2 %credentials = $recipe->client_credentials($guest, $name)

What lexicon needs on another guest to write C<$name> through the proxy on
C<$guest>, as L<Provisioner::Recipe::registrar/lexicon_credentials> returns it.  The
token is in C<key_file>, which C<issue_grant> puts there.

C<opts> is C<--resolve-zone-name>, so that lexicon asks the DNS for the zone.
The guest resolves its own zone through C<$guest>.  See
L<Provisioner::Recipe::registrar>.

C<zone> is C<$name>, because C<$guest> holds the zone of that name.  The guest
asks C<$guest> through the stub of systemd-resolved, which answers a name with
no record with the C<SOA> of the root and not of the zone.  So lexicon can find
the zone of C<$name> and not the zone of C<www.$name> before the challenge of
C<www.$name> is written.

=cut

sub client_credentials {
    my ( $self, $guest, $name ) = @_;

    return (
        type     => 'powerdns',
        user     => q{},
        key      => q{},
        key_file => $self->token_path($name),
        opts     => '--resolve-zone-name',
        zone     => $name,
        extra    => [ { key => 'PDNS_SERVER', value => "https://dnsapi.$guest" } ],
    );
}

=head2 $path = $recipe->token_path($name)

Where the token of C<$name> is, on the guest that writes C<$name>.

=cut

sub token_path {
    my ( $self, $name ) = @_;
    return "/etc/lexicon/$name.token";
}

=head2 %files = $recipe->issue_grant($grant, %terms)

The tokens that the guest of C<$grant> issues to its client, as C<issue_grant>
in L<Provisioner::Recipe> says.  A grant to this recipe is one of two kinds.

Without C<zones>, the guest holds the zone of the client, and the file is the
token that writes the client and the names below it, at C<token_path> of the
client.  The command is F<scripts/pdns_client> C<issue>.  It replaces the zone
and the token that a build before this one made, so each build starts from an
empty zone, which the guest fills again in its postrun.

With C<< zones => \@zones >>, the guest builds each of C<@zones> because an
account of L<Provisioner::Recipe::registrar> names it as the authority.
C<%terms> has C<< names => { $zone => \@names } >>, and for each zone with
names, the file is the token that lets the client write only those names and
their challenges, at C<token_path> of the zone.  The command is
F<scripts/pdns_client> C<grant>.  It leaves the zone alone, because other guests
serve names in it.  A zone with no names gets no token.

Dies as C<checked_names> does.

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    my ( $guest, $client ) = @{$grant}{qw{guest client}};

    my %commands;
    if ( !$grant->{zones} ) {
        $self->checked_names( $guest, $client );
        %commands = ( $client => "$Provisioner::Vars::SCRIPT_DIR/pdns_client issue $client $guest" );
    }
    foreach my $zone ( @{ $grant->{zones} // [] } ) {
        my @names = sort @{ $terms{names}{$zone} // next };
        $self->checked_names( $guest, $zone, $client, @names );
        $commands{$zone} = join( q{ }, "$Provisioner::Vars::SCRIPT_DIR/pdns_client grant", $zone, $client, @names );
    }

    return map { $self->token_path($_) => { issue => { guest => $guest, command => $commands{$_} }, owner => 'root:root', mode => '0600' } } keys %commands;
}

=head2 %revocation = $recipe->revoke_grant($grant)

How C<bin/destroy> takes C<$grant> back, as C<revoke_grant> in
L<Provisioner::Recipe> says.  Without C<zones>, F<scripts/pdns_client>
C<release> deletes the zone of the client and its token.  With C<zones>,
F<scripts/pdns_client> C<revoke> deletes the token of the client in each zone,
and the zones stay.  It asks about every zone of the grant, because a token
that is gone already is no error.  If the guest is not up, what it holds stays,
and C<bin/provision> replaces it when the client is built again.

Dies as C<checked_names> does.

=cut

sub revoke_grant {
    my ( $self,  $grant )  = @_;
    my ( $guest, $client ) = @{$grant}{qw{guest client}};

    my $replaced = "bin/provision replaces them when $client is built again";
    if ( !$grant->{zones} ) {
        $self->checked_names( $guest, $client );
        return (
            command => "$Provisioner::Vars::SCRIPT_DIR/pdns_client release $client",
            doing   => "remove the zone and the token of $client",
            done    => "Removed the zone and the token of $client",
            stays   => "the zone and the token of $client stay on it.  $replaced",
        );
    }

    my @zones = @{ $grant->{zones} };
    $self->checked_names( $guest, $client, @zones );
    return (
        command => join( ' ; ', map { "$Provisioner::Vars::SCRIPT_DIR/pdns_client revoke $_ $client" } @zones ),
        doing   => "remove the zone tokens of $client",
        done    => "Removed the zone tokens of $client",
        stays   => "the zone tokens of $client stay on it.  $replaced",
    );
}

=head2 $recipe->checked_names(@names)

Dies unless each of C<@names> is a domain in lower case, as
L<Data::Validate::Domain> judges it, with the reserved TLDs as private ones.
Each of them goes into a command that root runs on a pdns guest.

=cut

sub checked_names {
    my ( $self, @names ) = @_;

    my %private = map { $_ => 1 } Provisioner::Utils::reserved_tlds();
    foreach my $name (@names) {
        die "A command that root runs on a pdns guest takes domains, and '" . ( $name // q{} ) . "' is not one\n"
          unless defined $name && $name eq lc $name && Data::Validate::Domain::is_domain( $name, { domain_private_tld => \%private } );
    }

    return 1;
}

sub enrich {
    my ( $self, %opts ) = @_;

    my $extras = $opts{extra_records} // '';
    if ($extras) {
        my $is_abs_path = index( $extras, '/' ) == 0;
        $extras = "$opts{data_source}/$opts{domain}/$extras" unless $is_abs_path;
        $opts{extra_records} = File::Slurper::read_text($extras);
    }

    $opts{serial} = int time;

    $opts{api_socket}   = $API_SOCKET;
    $opts{api_key_file} = $API_KEY_FILE;

    my @ours = @{ $opts{transfer_ips} // [] };
    push( @ours, $opts{transfer_ip} ) if !@ours && $opts{transfer_ip};
    my %bins = Provisioner::IPPool::bins( $opts{ip_pool} // {} );
    my @pool = map { Provisioner::IPPool::pool_items( ( $bins{$Provisioner::IPPool::GUESTS} // {} )->{$_} ) } qw{cidr addresses};
    $opts{api_allowed} = [ uniq( qw{127.0.0.1 ::1}, @ours, @pool, sort( values %{ $opts{ipmap} // {} } ), @{ $opts{api_allow} } ) ];

    # Nobody can ask a server on loopback, and the zone above names this one.
    # The address of the guest, because a domain layered onto it has an
    # address of its own, and the server listens only where its guest does.
    $opts{public_address} = ( Provisioner::IPPool::guest_address( $opts{domain} ) )[1] // $opts{main_ip};

    $opts{acme_port} = Provisioner::Cookbook->load('acmeca')->port_for( $opts{domain} ) if any { $_ eq 'acmeca' } @{ $opts{modules} // [] };

    # Not every served name: pdns refuses a record outside its zone, and a name
    # in a zone of a registrar account is published there.  See zone_aliases
    # in Provisioner::Recipe::registrar.
    $opts{domain_aliases} = [ Provisioner::Cookbook->load('registrar')->zone_aliases(%opts) ];

    # The zones that an account of the registrar names this guest the authority
    # of, once for the guest and not again for a domain layered onto it.
    my $registrar = Provisioner::Cookbook->load('registrar');
    my $server    = Provisioner::Utils::dns_name( Provisioner::Cookbook->host_of( $opts{domain} ) // $opts{domain} );
    my %zones     = $registrar->configured_zones( $opts{domain} );
    my @held      = $server eq Provisioner::Utils::dns_name( $opts{domain} ) ? sort grep { Provisioner::Utils::dns_name( $zones{$_}{authority} // q{} ) eq $server } keys %zones : ();
    $self->checked_names(@held) if @held;
    $opts{held_zones}      = \@held;
    $opts{held_nameserver} = "ns1.$server";

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'pdns.zone.tt'         => 'zonefile',
        'pdns.held_zones.tt'   => 'pdns-held-zones.sh',
        'pdns.domain.tt'       => 'pdns-domain.conf',
        'pdns.global.tt'       => 'pdns-global.conf',
        'pdns.recursor.tt'     => 'pdns-recursor-domain.conf',
        'pdns.recursor.lua.tt' => 'pdns-recursor-domain.lua',
        'pdns.rsyslog.tt'      => '10-powerdns.conf',
        'pdns.api.tt'          => 'pdns-api.conf',
        'pdns.acl.psgi.tt'     => 'pdns-acl.psgi',
        'pdns.acl.service.tt'  => 'pdns-acl.service',
        'pdns.acl.nginx.tt'    => 'pdns-acl.nginx.conf',
        'pdns.acl.dropin.tt'   => 'pdns-acl.dropin.conf',
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The whole spool, because pdns opens everything relative to its chroot.
    # 0775, because the pdns group needs to write in the chroot.
    return ( '/var/spool/powerdns' => { from => "$install_dir/$domain/pdns", owner => 'pdns:pdns', mode => '0775' } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The sqlite database that holds every zone record of the guest.  After
        # a provision it differs from the zonefile, because lexicon writes the
        # DCV records into it, and people add records by hand.  A rebuild that
        # starts from the zonefile loses them.
        #
        # The whole spool comes down, because pdns opens everything relative to
        # its chroot.  The data target puts it back through restores, before
        # the global fragment applies the schema.
        #
        # One zones.db serves every domain on the guest, so only one salvage
        # can go back.  The salvages of the other domains stay in their domain
        # directories, and the guest test reports it.
        '/var/spool/powerdns/' => 'pdns/',
    );
}

sub formatters {
    my ($class) = shift;
    return (
        reverse_ip => Text::Xslate::html_builder(
            sub {
                my $ip = shift;
                return Net::IP->new($ip)->reverse_ip();
            }
        ),
        email_for_dns => Text::Xslate::html_builder(
            sub {
                my $email = shift;
                $email =~ tr/@/./;
                return $email;
            }
        ),
    );
}

sub tests {
    return qw{pdns.tt pdns.acl.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

The PowerDNS apt repository, which this recipe adds and installs from.

=cut

sub fetch_hosts {
    return qw{repo.powerdns.com};
}

=head2 @classes = $recipe->cache_classes()

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->apt_repo_classes('repo.powerdns.com');
}

1;
