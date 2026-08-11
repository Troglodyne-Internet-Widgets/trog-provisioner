package Provisioner::Recipe::ufw;

use 5.041;

use strict;
use warnings FATAL => 'all';

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

sub args {
    return (
        type       => 'object',
        properties => {
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
        'ufw.user.rules.tt' => 'ufw.user.rules',
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
