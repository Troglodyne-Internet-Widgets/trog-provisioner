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
See C<client_secret>.

The server answers on port 53 of the address of the guest, as well as on
loopback, because the zone above names this domain as the nameserver of each
of those zones.  It answers only for the zones that it holds, and refuses
everything else.  The recursor stays on loopback.

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
token on the other guest.  See C<client_secret>.  The token is labeled with the
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
                  'The credential everything on this guest presents to talk to the API on its loopback socket, such as lexicon writing an _acme-challenge record.  Made here when nobody sets one, because it is a secret nobody chose rather than a decision an operator has to make; a secret: reference is how you set one deliberately.  It belongs to the server, so a domain layered onto another guest presents that machine key rather than one of its own.',
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

=head2 %credentials = $recipe->lexicon_credentials(%opts)

The credentials for the API on the unix socket of this server.  Anything on
this guest writes a record into the zone of this server through that API.  See
L<Provisioner::Recipe::registrar/lexicon_credentials> for the keys that come
back.

C<opts> is C<--resolve-zone-name>, because lexicon reduces a name to its
registrable form with tldextract before it asks for a zone.  A reserved TLD is
not a public suffix, so without the flag lexicon asks for the zone "test" and
gets a 404.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    # The registrar calls this as a class method, on a path where enrich does not run.
    my $key =
        $opts{api_key}
      ? $opts{api_key}
      : $self->api_key_for( $opts{domain} );

    return (
        type  => 'powerdns',
        user  => q{},
        key   => $key,
        opts  => '--resolve-zone-name',
        extra => [ { key => 'PDNS_SERVER', value => $API_SOCKET } ],
    );
}

=head2 $key = $recipe->api_key_for($domain)

Returns the API key of the pdns server on the guest that holds C<$domain>.

If an operator set C<api_key> for that server, it returns that value.  If not,
it makes one random key per server and returns that key on each call.  The API
configuration, the dehydrated hook and the lexicon shortcut must present the
same key, because a different key gets a 401.

The server belongs to a guest, not to a domain.  For a domain that is layered
onto another guest, L<Provisioner::Cookbook/host_of> finds that guest, and the
method returns the key of its server.

=cut

sub api_key_for {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;

    my $configured = Provisioner::Cookbook->domain_config($server)->{ $self->recipe_name }{api_key};
    return $configured if $configured;

    state %made;
    return $made{ $server // q{} } //= Crypt::PRNG::random_bytes_hex(32);
}

=head2 %credentials = $recipe->client_credentials($guest, $name)

What lexicon needs on another guest to write C<$name> through the proxy on
C<$guest>, as L<Provisioner::Recipe::registrar/lexicon_credentials> returns it.  The
token is in C<key_file>, which C<client_secret> puts there.

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

=head2 %files = $recipe->client_secret($guest, $name)

The token that writes C<$name> and the names below it, in a zone of that name
on C<$guest>.  It is a file for the C<guest_secrets> of a recipe on the guest
that writes the name, with C<issue> in place of C<ref>: see C<guest_secrets> in
L<Provisioner::Recipe>.

The command is F<scripts/pdns_client> C<issue>, which root runs on C<$guest>.
It replaces the zone and the token that a build before this one made, so each
build starts from an empty zone, which the guest fills again in its postrun.

Dies as C<checked_names> does.

=cut

sub client_secret {
    my ( $self, $guest, $name ) = @_;

    $self->checked_names( $guest, $name );
    return (
        $self->token_path($name) => {
            issue => {
                guest   => $guest,
                command => "$Provisioner::Vars::SCRIPT_DIR/pdns_client issue $name $guest",
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 $command = $recipe->release_command($guest, $name)

The shell command that root runs on C<$guest> to delete the zone C<$name> and
the token labeled C<$name>: F<scripts/pdns_client> C<release>.  C<bin/destroy>
runs it for a guest that named C<$guest> as its authority.  Dies as
C<checked_names> does.

=cut

sub release_command {
    my ( $self, $guest, $name ) = @_;

    $self->checked_names( $guest, $name );
    return "$Provisioner::Vars::SCRIPT_DIR/pdns_client release $name";
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

    $opts{api_key} = $self->api_key_for( $opts{domain} )
      unless $opts{api_key};

    my $extras = $opts{extra_records} // '';
    if ($extras) {
        my $is_abs_path = index( $extras, '/' ) == 0;
        $extras = "$opts{data_source}/$opts{domain}/$extras" unless $is_abs_path;
        $opts{extra_records} = File::Slurper::read_text($extras);
    }

    $opts{serial} = int time;

    $opts{api_socket} = $API_SOCKET;

    my @ours = @{ $opts{transfer_ips} // [] };
    push( @ours, $opts{transfer_ip} ) if !@ours && $opts{transfer_ip};
    my %bins = Provisioner::IPPool::bins( $opts{ip_pool} // {} );
    my @pool = map { Provisioner::IPPool::pool_items( ( $bins{$Provisioner::IPPool::GUESTS} // {} )->{$_} ) } qw{cidr addresses};
    $opts{api_allowed} = [ uniq( qw{127.0.0.1 ::1}, @ours, @pool, sort( values %{ $opts{ipmap} // {} } ), @{ $opts{api_allow} } ) ];

    # Nobody can ask a server on loopback, and the zone above names this one.
    $opts{public_address} = $opts{main_ip};

    $opts{acme_port} = Provisioner::Cookbook->load('acmeca')->port_for( $opts{domain} ) if any { $_ eq 'acmeca' } @{ $opts{modules} // [] };

    # Not every served name: pdns refuses a record outside its zone, and a name
    # in a zone of a registrar account is published there.  See zone_aliases
    # in Provisioner::Recipe::registrar.
    $opts{domain_aliases} = [ Provisioner::Cookbook->load('registrar')->zone_aliases(%opts) ];

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'pdns.zone.tt'         => 'zonefile',
        'pdns.domain.tt'       => 'pdns-domain.conf',
        'pdns.global.tt'       => 'pdns-global.conf',
        'pdns.recursor.tt'     => 'pdns-recursor-domain.conf',
        'pdns.recursor.lua.tt' => 'pdns-recursor-domain.lua',
        'pdns.rsyslog.tt'      => '10-powerdns.conf',
        'pdns.api.tt'          => 'pdns-api.conf',
        'pdns.acl.psgi.tt'     => 'pdns-acl.psgi',
        'pdns.acl.env.tt'      => 'pdns-acl.env',
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
