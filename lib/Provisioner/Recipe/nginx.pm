package Provisioner::Recipe::nginx;

#ABSTRACT: Set up nginx on the server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};


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
            # Room for the longest server_name there can be.  A domain name
            # is at most 253 characters, so 256 -- the next multiple of the
            # cache line nginx wants this aligned to -- always fits and never
            # needs thinking about again.
            server_names_hash_bucket_size =>
                { type => 'integer', default => 256, minimum => 32 },
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
