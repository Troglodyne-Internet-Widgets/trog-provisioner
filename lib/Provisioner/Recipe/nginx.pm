package Provisioner::Recipe::nginx;

#ABSTRACT: Install nginx and its global configuration.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Provisioner::Cookbook();
use Provisioner::IPPool();
use List::Util();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginx

=head2 SYNOPSIS

    somedomain:
        nginx:
            backlog: 32768

=head2 DESCRIPTION

Install nginx, set the kernel backlog and worker_connections to C<backlog>, and
install the global configuration of nginx.

With C<syslog>, the default, nginx also sends its access log and its error log
to the syslog of the guest, tagged C<nginx_access> and C<nginx_error>.  So
L<Provisioner::Recipe::logshipper> forwards them.  The files stay, because the
jails of fail2ban read them.  A server block that names its own C<access_log>
replaces the one sent to syslog, so the mirrors of C<aptmirror> and
C<fetchcache> do not send their traffic there.

=head2 USE AS DEPENDENCY

Use this recipe as a dependency of other nginx recipes, not on its own.

=head2 The names that each vhost answers for

nginx gives a name that two server blocks claim to the first one it loads, and
only warns about the other.  So the names of every vhost of a domain are decided
here, in one place.

A recipe that installs a vhost lists the names of its vhost in C<sites>, from
its C<required_recipes>:

    nginx => sub {
        my (%opts) = @_;
        return ( sites => ["webmail.$opts{domain}"] );
    },

A vhost that serves the primary domain being provisioned lists that domain.
That vhost also answers for every alias that the operator configured for the
domain and no other vhost lists, so it does not know its names in advance.  The fragment of this recipe
writes them to F</etc/nginx/names/$domain.conf> as its C<server_name>, and
that vhost includes the file.  A vhost writes the names that it lists itself
in a C<server_name> of its own, such as C<www> beside that file.

A name that two recipes list stops the build, because nginx would serve only
one of them.  So two recipes whose vhosts serve the domain cannot be on one
guest.

=head2 Names that reach the guest through a proxy

C<public_names> maps each name under which the internet reaches this guest,
through a proxy elsewhere such as an edge guest on the VPN, to the vhost that
answers for it.  The proxy passes TLS through by its SNI name, so the guest
keeps its own certificate.  It speaks the PROXY protocol, so the guest learns
the address of the real client.

    internal.somedomain:
        nginx:
            public_names:
                shop.internal.somedomain: internal.somedomain
                webmail.customer.example: webmail.internal.somedomain

The vhost is named by a name that a recipe lists in C<sites>.  A name that the
vhost of the domain answers for, such as C<www> or an alias, names that vhost.
The build stops when a vhost is in no C<sites>, when a public name is one that
another vhost lists, and when a vhost is outside the zone of the domain, which
is the domain or a name below it.

Each vhost that a public name names also listens on 8443 with TLS and the PROXY
protocol, and on 8080 without TLS, where the proxy connects.  The proxy routes
plain HTTP by its C<Host> header, and nginx can send a PROXY header only from a
proxy that does not read it.  So on 8080 the address of the client comes in
C<X-Forwarded-For>.  Its listeners
on 443 and 80 stay as they are for the LAN.  A vhost that no public name names
does not listen for the proxy at all, and a name that no vhost claims on those
ports gets no answer.  The ufw application profile C<nginx-proxy> opens the two
ports.  They listen on IPv4 only, because the proxy reaches the guest through
the IPv4 tunnel of openvpn, so they need nothing from a guest that turns IPv6
off.

A public name inside the zone of the domain joins the names that this recipe
serves.  So the registrar publishes it, and letsencrypt puts it on the
certificate, as for any other served name.  So does a public name in a zone
that an account of L<Provisioner::Recipe::registrar> lists, which publishes it
in that zone.  Any other public name gets neither, because no DNS-01 challenge can
answer for it.  Then
C<public.VHOST> joins the served names in its place, and its vhost answers for
it.  It is published, certified and proxied, so the path through the proxy
works before the owner of the outside name changes anything.

nginx believes the address in a PROXY header or in C<X-Forwarded-For> only
from C<proxy_from>.  A client anywhere else that sends one keeps its own
address in the logs.  The default of
C<proxy_from> is each network of C<ip_pool> that a bin routes through an
openvpn server, which is where the edge gets its address.  See
L<Provisioner::IPPool/BINS>.

=head2 Registration with an edge guest

    internal.somedomain:
        nginx:
            edge: edge.somedomain
            public_names:
                shop.internal.somedomain: internal.somedomain

C<edge> names the guest that runs L<Provisioner::Recipe::edge>.  When this
domain has public names, C<bin/provision> registers them there before the
makefile starts, so the edge must be up first.  The edge sends each name in
C<proxied_names> to the address of this guest in the address pool, on the
ports of C<proxy_ports>.  A domain built onto another guest registers the
address of that guest.

The edge refuses a name that another domain registered.  It issues a key for
this domain, which lands at F</etc/fail2ban/edge/DOMAIN.key.b64>.

C<bin/destroy> releases the names on the edge.  If the edge is not up then, it
warns and says what to run there.  Until then, the edge sends those names to an
address that the pool can give to the next guest.

=head2 Bans through the edge

A ban on this guest blocks nothing that comes through the edge, because those
packets come from the edge.  So with C<edge> and a public name, each jail of
this recipe also bans through the action C<edge-DOMAIN>.  It runs
C<edge_ban> on the edge over ssh, with the key that the edge issued, and the
edge drops the address.  See L<Provisioner::Recipe::edge/Bans>.

The edge also issues its host key, which this guest pins in
F</etc/fail2ban/edge/DOMAIN.known_hosts>, so a ban never goes to a guest that
only claims to be the edge.  The jails never ban the address of the edge.  That
address is the one in L<Provisioner::Recipe::edge/address>, and it goes into
C<ignoreip> beside loopback.

The jails of other recipes still ban through ufw only, because what they read
does not come through the edge.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    # One page load opens dozens of connections to one origin, and a shared NAT
    # multiplies that by each user behind it.  A thousand a second is not a visitor.
    my %limits = ( 80 => 1024, 443 => 1024 );

    # The proxy carries every client of the public names, so its listeners get
    # the limit of the ports it fronts.
    my %proxy = $self->proxy_ports();
    %limits = ( %limits, map { $proxy{$_} => $limits{$_} } keys %proxy ) if %{ $opts{public_names} // {} };
    return %limits;
}

=head2 %ports = $recipe->proxy_ports()

Each port that the proxy fronts, mapped to the port of the guest that the proxy
connects to for it, with the PROXY protocol.  The templates of this recipe
write the same numbers.  See L</Names that reach the guest through a proxy>.

=cut

sub proxy_ports {
    return ( 443 => 8443, 80 => 8080 );
}

=head2 %jails = $recipe->jails()

The jails that fail2ban ships for nginx: failed basic authentication, and
requests for the paths that bots probe.  Both read the error log of nginx, so
both read the file and not the journal.

=cut

sub jails {
    return (
        'nginx-http-auth' => { backend => 'auto' },
        'nginx-botsearch' => { backend => 'auto' },
    );
}

=head2 %required = $recipe->required_recipes()

C<letsencrypt>, which reloads C<nginx> when it links or renews the certificate
that the vhosts serve.

=cut

sub required_recipes {
    return ( letsencrypt => sub { return ( certificate_readers => ['nginx'] ) } );
}

sub args {
    return (
        properties => {
            backlog => { type => 'integer', default => 32768, minimum => 0 },

            # A domain name is at most 253 characters.  256 is the next multiple
            # of the cache line size, which nginx aligns this value to.
            server_names_hash_bucket_size => { type => 'integer', default => 256, minimum => 32 },

            syslog => {
                type        => 'boolean',
                default     => 1,
                description => 'Also send the access log and the error log to the syslog of the guest, which logshipper forwards.  The files stay either way, because fail2ban reads them.',
            },

            public_names => {
                type                 => 'object',
                propertyNames        => { format => 'hostname' },
                additionalProperties => { type   => 'string', format => 'hostname' },
                default              => {},
                description          =>
                  'Each name under which the internet reaches this guest through a proxy that speaks the PROXY protocol, such as an edge guest, mapped to a name of the vhost that answers for it.  A public name in the zone of the domain, or in a zone that an account of the registrar lists, is also published and certified.  For any other name, public.VHOST is published and certified instead.  See "Names that reach the guest through a proxy".',
            },

            edge => {
                type        => 'string',
                format      => 'hostname',
                description => 'The guest that runs the edge recipe, where the public names of this domain are registered when it is built.  Read only when public_names has a name.  See "Registration with an edge guest".',
            },

            proxy_from => {
                type        => 'array',
                items       => { type => 'string' },
                description => 'The networks, as CIDR blocks, whose PROXY header nginx believes.  The default is each network of ip_pool that a bin routes through an openvpn server.  Read only when public_names has a name.',
            },

            sites => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'The names that the vhosts of the domain answer for, which the recipes that install them hand over.  The vhost that serves the primary domain being provisioned lists it, and also answers for each alias that no other vhost lists.  See "The names that each vhost answers for".',
            },
        },
    );
}

# The vhost that answers for $name: the domain for a name of the vhost of the
# domain, www or an alias, because that vhost includes the files of the domain
# only, and otherwise $name.
my sub vhost_of ( $name, %opts ) {
    my %of_domain = map { $_ => 1 } "www.$opts{domain}", @{ $opts{aliases}{ $opts{domain} } // [] };
    return $of_domain{$name} ? $opts{domain} : $name;
}

# The public names of each vhost, as a map of the vhost to the names.
my sub public_names_by_vhost (%opts) {
    my %by_vhost;
    my $public = $opts{public_names} // {};
    foreach my $name ( sort keys %$public ) {
        push( @{ $by_vhost{ vhost_of( $public->{$name}, %opts ) } }, $name );
    }
    return %by_vhost;
}

my sub in_zone ( $name, $domain ) {
    return $name =~ m/(?:\A|[.])\Q$domain\E\z/i;
}

# Whether a DNS-01 challenge can answer for $name: it is in the zone of the
# domain, or in a zone that an account of the registrar lists.
my sub certifiable ( $name, $domain ) {
    return in_zone( $name, $domain ) || defined Provisioner::Cookbook->load('registrar')->zone_of( $name, $domain );
}

# Each vhost that a public name names, mapped to every name that it answers
# for on the ports of the proxy: the public names that it can certify, then
# public.VHOST when a public name is not one, then the others.
my sub proxied_by_vhost (%opts) {
    my %by_vhost = public_names_by_vhost(%opts);
    my %names;
    foreach my $vhost ( keys %by_vhost ) {
        my @inside  = grep { certifiable( $_,  $opts{domain} ) } @{ $by_vhost{$vhost} };
        my @outside = grep { !certifiable( $_, $opts{domain} ) } @{ $by_vhost{$vhost} };
        $names{$vhost} = [ @inside, ( @outside ? "public.$vhost" : () ), @outside ];
    }
    return %names;
}

=head2 @names = $recipe->served_names(%opts)

The names of the base class, then each public name in the zone of the domain
or in a zone that an account of the registrar lists, then C<public.VHOST> for
each vhost that answers for a public name in neither.  See L</Names that reach the guest through a proxy>.

=cut

sub served_names {
    my ( $self, %opts ) = @_;

    my %proxied = proxied_by_vhost(%opts);
    return (
        $self->SUPER::served_names(%opts),
        map {
            grep { certifiable( $_, $opts{domain} ) }
              @{ $proxied{$_} }
        } sort keys %proxied
    );
}

=head2 @names = $recipe->proxied_names(%opts)

Every name that the guest answers for on the ports of the proxy, sorted: each
public name, and C<public.VHOST> for each vhost that answers for a public name
that it cannot certify.  A proxy routes these names to the guest.  It needs
C<public_names>, C<domain>, and the C<aliases> of the domain.

=cut

sub proxied_names {
    my ( $self, %opts ) = @_;

    my %proxied = proxied_by_vhost(%opts);
    my @names   = sort { $a cmp $b } List::Util::uniq( map { @$_ } values %proxied );
    return @names;
}

=head2 @grants = $recipe->grants($domain, %opts)

With C<edge> and a public name, the registration of the names of C<$domain> on
the edge, as C<grants> in L<Provisioner::Recipe> says.  The edge issues a key
for it, and releases the names when the domain goes away.  See
L<Provisioner::Recipe::edge/issue_grant> and L</Registration with an edge guest>.

=cut

sub grants {
    my ( $self, $domain, %opts ) = @_;
    my $edge = $opts{edge};
    return () unless defined $edge && %{ $opts{public_names} // {} };

    return { recipe => 'edge', guest => $edge, client => $domain };
}

=head2 %terms = $recipe->grant_terms($grant, %opts)

Where the edge sends TLS and plain HTTP for the client of C<$grant>, and the
names that it sends there, as L<Provisioner::Recipe::edge/issue_grant> takes
them.

Dies when the guest of the client has no address in the address pool, because
the edge reaches the guest by that address.

=cut

sub grant_terms {
    my ( $self, $grant, %opts ) = @_;
    my $domain = $grant->{client};

    my ( $guest, $address ) = Provisioner::IPPool::guest_address($domain);
    die "nginx: $domain registers its public names on $grant->{guest}, which reaches them at the address of $guest.  $guest has no address in " . Provisioner::IPPool::db_path() . ".\n"
      unless defined $address;

    my %port = $self->proxy_ports();
    return (
        upstreams => { tls => "$address:$port{443}", http => "$address:$port{80}" },
        names     => [ $self->proxied_names( %opts, domain => $domain, aliases => Provisioner::Cookbook->alias_map() ) ],
    );
}

=head2 %opts = $recipe->enrich(%opts)

When a vhost serves the domain, adds C<domain_names>: the domain, and each alias
of it that no vhost lists and that is not a public name.  When C<public_names>
has a name, adds C<proxied>, a map of each vhost that answers for a public name
to the names that it answers for on the ports of the proxy, less the names that
the vhost has already.  Then it fills in C<proxy_from> from C<ip_pool> if it is not set.

Dies when two recipes list one name, when a public name names a vhost that no
recipe lists or one outside the zone of the domain, when another vhost lists a
public name, and when there are public names and no network to believe a PROXY
header from.

With C<edge> and a public name, it also adds C<edge_address>, where this guest
reaches the edge, and C<edge_jails>, the jails that ban through it.  See
L</Bans through the edge>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my %listed;
    $listed{$_}++ foreach @{ $opts{sites} };
    foreach my $name ( sort keys %listed ) {
        die "nginx: invalid configuration: multiple recipes configured to serve $name\n" if $listed{$name} > 1;
    }

    my %proxied = proxied_by_vhost(%opts);
    if (%proxied) {
        my %by_vhost = public_names_by_vhost(%opts);
        foreach my $vhost ( sort keys %by_vhost ) {
            my $names = join( ', ', @{ $by_vhost{$vhost} } );
            die "nginx: public_names points $names at $vhost, but no recipe on $opts{domain} lists $vhost in sites.\n"
              unless $listed{$vhost};
            die "nginx: public_names points $names at $vhost, but $vhost is outside the zone of $opts{domain}, so public.$vhost cannot be certified.\n"
              unless in_zone( $vhost, $opts{domain} );
            my @taken = grep { $listed{$_} && vhost_of( $_, %opts ) ne $vhost } @{ $by_vhost{$vhost} };
            die "nginx: public_names points " . join( ', ', @taken ) . " at $vhost, but each is a name that another vhost lists in sites.\n"
              if @taken;
        }
        $opts{proxied} = {
            map {
                my $vhost = $_;
                ( $vhost => [ grep { vhost_of( $_, %opts ) ne $vhost } @{ $proxied{$vhost} } ] )
            } keys %proxied
        };

        my %bins = Provisioner::IPPool::bins( $opts{ip_pool} // {} );
        $opts{proxy_from} //= [ map { Provisioner::IPPool::blocks( $bins{$_} ) } grep { defined $bins{$_}{via} } sort keys %bins ];
        die "nginx: $opts{domain} has public_names, but nothing says where the proxy connects from.  Give a bin of ip_pool a via, or set proxy_from.\n"
          unless @{ $opts{proxy_from} };

        if ( defined $opts{edge} ) {
            $opts{edge_address} = Provisioner::Cookbook->load('edge')->address( $opts{edge} );
            $opts{edge_jails}   = [ sort keys %{ { $self->jails(%opts) } } ];
        }
    }

    if ( $listed{ $opts{domain} } ) {
        my %public;
        $public{$_} = 1 foreach map { @$_ } values %{ $opts{proxied} // {} };
        $opts{domain_names} = [ $opts{domain}, grep { !$listed{$_} && !$public{$_} } $self->domain_aliases(%opts) ];
    }

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt' => 'nginx.global.conf',
        'nginx.sysctl.conf.tt' => 'nginx.sysctl.conf',
        'nginx.ufw.conf.tt'    => 'nginx_proxy_ufw.conf',
        'nginx.edge.action.tt' => 'nginx_edge.action',
        'nginx.edge.jail.tt'   => 'nginx_edge.jail',
    );
}

sub tests {
    return qw{nginx.tt};
}

1;
