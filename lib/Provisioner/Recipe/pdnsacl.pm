package Provisioner::Recipe::pdnsacl;

#ABSTRACT: Open the PowerDNS API of this guest to other guests, each with a token of its own.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util qw{uniq};

use Provisioner::Recipe::pdns();

=head1 Provisioner::Recipe::pdnsacl

=head2 SYNOPSIS

    somedomain:
        pdns:
        pdnsacl:
            # Optional.  More networks that may reach the API.
            allow:
                - 198.51.100.0/24

=head2 DESCRIPTION

The API of L<Provisioner::Recipe::pdns> listens only on a unix socket on the
guest, so nothing else can write a record into a zone that the guest serves.
This recipe opens it to other guests through L<PowerDNS::API::ACL>.

A client presents a token of its own as its API key.  A grant lets a token read
or write the records of one name, or every name under a name, in one zone, or
create and delete one zone.  The proxy checks each request against the grants,
and passes an allowed one to pdns with the real key.  So a guest can publish
its own records and nothing else.

The API answers at C<dnsapi.$domain>, over TLS.  That name is one of the
C<subdomains> of this recipe, so it gets a record and a certificate as every
served name does.  The vhost answers only the addresses that this installation
gives its guests, the addresses of this machine, the guest itself, and the
networks in C<allow>.

Starman runs the proxy as the C<pdns> user.  pdns creates its API socket with
its umask, which leaves the group no write, and a client needs to write to a
socket to connect.  So this recipe gives pdns a drop-in that sets its umask to
C<0002>.  Other files that pdns creates become writable by the C<pdns> group
too, which the pdns recipe already makes of everything under
F</var/spool/powerdns>.
The tokens are in F</var/lib/pdns-acl/acl.db>.  This recipe makes none.  Make
one on the guest with C<pdns-acl>, as the C<pdns> user so that the database
stays its own.  Name the perl that the perl recipe built: C<pdns-acl> starts
with C</usr/bin/env perl>, and the PATH of C<sudo> finds the system perl, which
has none of the modules.

    sudo -u pdns /opt/perl5/current/bin/perl /opt/perl5/current/bin/pdns-acl \
        token add web1 --zone lab.example.net. --name web1.lab.example.net. --write

=cut

=head2 @names = $recipe->subdomains()

C<dnsapi>, where the API answers.

=cut

sub subdomains {
    return qw{dnsapi};
}

sub required_recipes {
    my ( $self, %opts ) = @_;

    return (
        pdns => sub { return () },

        # The perl target runs after this fragment, so the service starts in
        # the postrun, when Starman and the proxy are installed.
        # 0.002 is the first release that reaches pdns over its socket: before
        # it, HTTP::Tiny died on every request there.
        perl  => sub { return ( cpan_deps => [ { install => [ 'Starman', 'PowerDNS::API::ACL~>= 0.002' ] } ] ) },
        nginx => sub { return ( sites     => [ $self->served_names(%opts) ] ) },
    );
}

sub args {
    return (
        properties => {
            allow => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'More addresses or networks that may reach the API, beside the guests of this installation, the addresses of this machine and the guest itself.  For a guest that reaches it through NAT, name the address it arrives from.',
            },
            ipv6 => { type => 'boolean', default => 1 },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<api_key>, the key of the pdns server of this guest, as
L<Provisioner::Recipe::pdns/api_key_for> gives it, and C<api_socket>, where
that server listens.  Adds C<allowed>: every address that may reach the API,
each once.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{api_key}    = 'Provisioner::Recipe::pdns'->api_key_for( $opts{domain} );
    $opts{api_socket} = $Provisioner::Recipe::pdns::API_SOCKET;

    my @ours = @{ $opts{transfer_ips} // [] };
    push( @ours, $opts{transfer_ip} ) if !@ours && $opts{transfer_ip};
    $opts{allowed} = [ uniq( qw{127.0.0.1 ::1}, @ours, sort( values %{ $opts{ipmap} // {} } ), @{ $opts{allow} } ) ];

    return %opts;
}

sub template_files {
    return (
        'pdnsacl.psgi.tt'        => 'pdnsacl.psgi',
        'pdnsacl.env.tt'         => 'pdnsacl.env',
        'pdnsacl.service.tt'     => 'pdnsacl.service',
        'pdnsacl.nginx.tt'       => 'pdnsacl.nginx.conf',
        'pdnsacl.pdns-dropin.tt' => 'pdnsacl.pdns-dropin.conf',
    );
}

sub tests {
    return qw{pdnsacl.tt};
}

1;
