package Provisioner::Recipe::ufw;

use strict;
use warnings;

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

sub validate {
    my ( $self, %vars ) = @_;

    if ( $vars{port_forwards} ) {
        die "port_forwards must be ARRAY" unless ref $vars{port_forwards} eq 'ARRAY';
        foreach my $cron ( @{ $vars{port_forwards} } ) {
            die "Each port forward must be a HASH" unless ref $cron eq 'HASH';
            die "port forwards must have a from & to" unless $cron->{from} && $cron->{to};
        }
    }

    return %vars;
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
