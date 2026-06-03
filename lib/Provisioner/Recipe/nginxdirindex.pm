package Provisioner::Recipe::nginxdirindex;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxdirindex

=head2 SYNOPSIS

    somedomain:
        nginxdirindex:
            backlog: 32768
            ipv6: true

=head2 DESCRIPTION

Sets up an nginx vhost that serves directory listings (autoindex on) directly
from [% install_dir %]/[% domain %].

Useful for public file distribution, download mirrors, or static media serving
where directory browsing is desired rather than application proxying.

Shares the same kernel/nginx global tuning as nginxproxy (sysctl backlog,
worker_connections, server_names_hash_bucket_size).

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{nginx-full};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    $opts{backlog} //= 32768;
    die "nginxdirindex.backlog must be a positive integer"
        unless $opts{backlog} =~ /^\d+$/ && $opts{backlog} > 0;

    $opts{ipv6} //= 1;
    $opts{ipv6} = $opts{ipv6} ? 1 : 0;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt'         => 'nginx.global.conf',
        'nginx.sysctl.conf.tt'         => 'nginx.sysctl.conf',
        'nginxdirindex.domain.conf.tt' => 'nginxdirindex.domain.conf',
        'openssl.tt'                   => 'openssl.conf',
    );
}

1;
