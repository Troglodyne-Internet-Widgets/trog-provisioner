package Provisioner::Recipe::nginx;

#ABSTRACT: Set up nginx on the server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

=head1 Provisioner::Recipe::nginx

=head2 SYNOPSIS

    somedomain:
        nginx:
            backlog: 32768

=head2 DESCRIPTION

Setup nginx on the server.

=head2 USE AS DEPENDENCY

In general it is best to use this as a dependency to other nginx recipes.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{nginx-full};
    }
    die "Unsupported packager";
}

sub args {
    return (
        properties => {
            backlog => { type => 'integer', default => 32768, minimum => 0 },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt'  => 'nginx.global.conf',
        'nginx.sysctl.conf.tt'  => 'nginx.sysctl.conf',
        #XXX TODO this needs to be in the MAIN target, NOT here
        'openssl.tt' => 'openssl.conf',
    );
}

sub tests {
    return qw{nginx.tt};
}

1;
