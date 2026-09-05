package Provisioner::Recipe::ufw;

#ABSTRACT: Set up firewall rules for the enabled recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ufw

=head2 SYNOPSIS

    somedomain:
        ufw:
            port_forwards:
                - from: 25
                  to: 2500

=head2 DESCRIPTION

Sets up application rules for all your enabled recipes (and whatever else is installed on the system).

Optionally set up port forwarding.

=cut

use File::Path qw{rmtree};

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{ufw};
    }
    die "Unsupported packager";
}

sub enrich {
    my ($self, %opts) = @_;

    # The hypervisor is always one, whether or not anybody said so: it is what
    # the guest fetches its payload from, over ssh, repeatedly.
    my @nets = @{ $opts{admin_networks} // [] };
    unshift @nets, $opts{hv_ip} if $opts{hv_ip} && !grep { $_ eq $opts{hv_ip} } @nets;
    $opts{admin_networks} = \@nets;

    return %opts;
}

sub args {
    return (
        type       => 'object',
        properties => {
            # New connections a second a single source may open to a port
            # before it is dropped.  ufw's own `limit` is six in thirty seconds,
            # which is right for ssh and rate limits real visitors off a web
            # server -- so setup-ufw-rules limits only OpenSSH and these are the
            # real limits.
            #
            # Only ssh is named here, because ssh is the one port every guest
            # has whether or not any recipe asked for it.  The rest arrive from
            # the recipes that actually listen, through their rate_limits: see
            # Provisioner::Recipe::rate_limits.  Setting a port here still wins
            # if it is higher, which is how an operator raises one.
            rate_limits => {
                type    => 'object',
                default => { 22 => 64 },
            },
            # Networks allowed in without ufw's rate limit.  Its limit denies a
            # source that opens six connections in thirty seconds, and a
            # provision opens far more than that -- so without an exemption the
            # provisioner throttles itself out of the guest partway through
            # building it, and everything after that fails as "connection
            # refused" on an address that worked a minute earlier.
            admin_networks => {
                type    => 'array',
                items   => { type => 'string' },
                default => [],
            },
            port_forwards => {
                type  => 'array',
                items => {
                    type       => 'object',
                    required   => [qw{from to}],
                    properties => {
                        from => { type => 'integer' },
                        to   => { type => 'integer' },
                    },
                },
            },
        },
    );
}

my %template2rule = (
    'ufw.pdns.tt'            => 'ufw/pdns',
    'ufw.mail.tt'            => 'ufw/mail',
    'ufw.plexmediaserver.tt' => 'ufw/plexmediaserver',
    'ufw.garage.tt'          => 'ufw/garage',
    'ufw.redis.tt'           => 'ufw/redis',
    'ufw.openvpn.tt'         => 'ufw/openvpn',
);

sub template_files {
    my ( $self, @recipes ) = @_;

    my $dir = "$self->{output_dir}/ufw";

    rmtree $dir;
    mkdir $dir;

    # Only render things we actually need
    my %ret = (
        'ufw.rsyslog.tt' => 'ufw/rsyslog',
        'ufw.http.tt'    => 'ufw/http',
    );

    return %ret unless @recipes;

    foreach my $r (@recipes) {
        my $key = "ufw.$r.tt";
        $ret{$key} = $template2rule{$key} if exists $template2rule{$key};
    }

    return %ret;
}

sub tests {
    return qw{ufw.tt};
}

1;
