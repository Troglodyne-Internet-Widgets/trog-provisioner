package Provisioner::Recipe::nginx;

#ABSTRACT: Install nginx and its global configuration.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{uniq};

use Provisioner::IPPool();

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

C<public_names> lists the names under which the internet reaches this guest
through a proxy elsewhere, such as an edge guest on the VPN.  The proxy passes
TLS through by its SNI name, so the guest keeps its own certificate.  It speaks
the PROXY protocol, so the guest learns the address of the real client.

    somedomain:
        nginx:
            public_names:
                - somedomain
                - shop.somedomain
                - www.customer.example

The vhost of the domain answers for every public name, beside its other names.
So a public name cannot be one that another vhost lists in C<sites>, and a
guest with public names needs a vhost that serves the domain.

A public name inside the zone of the domain, which is the domain or a name below
it, joins the names that this recipe serves.  So the registrar publishes it,
and letsencrypt puts it on the certificate, as for any other served name.  A
public name outside that zone gets neither, because no DNS-01 challenge can
answer for it.  Then C<public.$domain> joins the served names in its place.  It
is published, certified and proxied, so the path through the proxy works before
the owner of the outside name changes anything.

The vhost of the domain also listens on 8443 with TLS and on 8080 without, each
with the PROXY protocol, where the proxy connects.  The ufw application profile
C<nginx-proxy> opens the two ports.  The listeners on 443 and 80 stay as they
are for the LAN.

nginx believes the address in a PROXY header only from C<proxy_from>.  A client
anywhere else that sends one keeps its own address in the logs.  The default of
C<proxy_from> is each network of C<ip_pool> that a bin routes through an
openvpn server, which is where the edge gets its address.  See
L<Provisioner::IPPool/BINS>.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;

    # One page load opens dozens of connections to one origin, and a shared NAT
    # multiplies that by each user behind it.  A thousand a second is not a visitor.
    my %limits = ( 80 => 1024, 443 => 1024 );

    # The proxy carries every client of the public names, so its listeners get
    # the limit of the ports it fronts.
    %limits = ( %limits, 8080 => 1024, 8443 => 1024 ) if @{ $opts{public_names} // [] };
    return %limits;
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
                type        => 'array',
                items       => { type => 'string', format => 'hostname' },
                default     => [],
                description => 'The names under which the internet reaches this guest through a proxy that speaks the PROXY protocol, such as an edge guest.  The vhost of the domain answers for each.  A name in the zone of the domain is also published and certified.  For a name outside it, public.DOMAIN is published and certified instead.  See "Names that reach the guest through a proxy".',
            },

            proxy_from => {
                type        => 'array',
                items       => { type => 'string' },
                description => 'The networks, as CIDR blocks, whose PROXY header nginx believes.  The default is each network of ip_pool that a bin routes through an openvpn server.  Read only when public_names lists a name.',
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

# The public names inside the zone of the domain, and those outside it, as two
# arrayrefs.  The domain itself is inside.
my sub public_names_by_zone (%opts) {
    my $zone  = qr/(?:\A|[.])\Q$opts{domain}\E\z/i;
    my @names = @{ $opts{public_names} // [] };
    return ( [ grep { m/$zone/ } @names ], [ grep { !m/$zone/ } @names ] );
}

=head2 @names = $recipe->served_names(%opts)

The names of the base class, then each of C<public_names> in the zone of the
domain, then C<public.$domain> when a public name is outside that zone.  See
L</Names that reach the guest through a proxy>.

=cut

sub served_names {
    my ( $self, %opts ) = @_;

    my ( $inside, $outside ) = public_names_by_zone(%opts);
    return ( $self->SUPER::served_names(%opts), @$inside, ( @$outside ? "public.$opts{domain}" : () ) );
}

=head2 %opts = $recipe->enrich(%opts)

When a vhost serves the domain, adds C<domain_names>: the domain, each alias of
it that no vhost lists, and each public name outside its zone.  When
C<public_names> lists a name, fills in C<proxy_from> from C<ip_pool> if it is
not set.

Dies when two recipes list one name, when another vhost lists a public name,
when there are public names and no vhost serves the domain, and when there are
public names and no network to believe a PROXY header from.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my %listed;
    $listed{$_}++ foreach @{ $opts{sites} };
    foreach my $name ( sort keys %listed ) {
        die "nginx: invalid configuration: multiple recipes configured to serve $name\n" if $listed{$name} > 1;
    }

    my @public = @{ $opts{public_names} };
    if (@public) {
        die "nginx: $opts{domain} has public_names, but no vhost on it serves $opts{domain}, and that vhost is the one that answers for them.\n"
          unless $listed{ $opts{domain} };
        my ($taken) = grep { $_ ne $opts{domain} && $listed{$_} } @public;
        die "nginx: $taken is in public_names, but another vhost lists it in sites.  Only the vhost of $opts{domain} listens for the proxy.\n"
          if defined $taken;

        my %bins = Provisioner::IPPool::bins( $opts{ip_pool} // {} );
        $opts{proxy_from} //= [ map { Provisioner::IPPool::blocks( $bins{$_} ) } grep { defined $bins{$_}{via} } sort keys %bins ];
        die "nginx: $opts{domain} has public_names, but nothing says where the proxy connects from.  Give a bin of ip_pool a via, or set proxy_from.\n"
          unless @{ $opts{proxy_from} };
    }

    if ( $listed{ $opts{domain} } ) {
        my ( undef, $outside ) = public_names_by_zone(%opts);
        $opts{domain_names} = [ uniq( $opts{domain}, grep( { !$listed{$_} } $self->domain_aliases(%opts) ), @$outside ) ];
    }

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt' => 'nginx.global.conf',
        'nginx.sysctl.conf.tt' => 'nginx.sysctl.conf',
        'nginx.ufw.conf.tt'    => 'nginx_proxy_ufw.conf',
    );
}

sub tests {
    return qw{nginx.tt};
}

1;
