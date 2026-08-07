package Provisioner::Recipe::nginxdirindex;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxdirindex

=head2 SYNOPSIS

    somedomain:
        nginxdirindex:
            ipv6: true

=head2 DESCRIPTION

Sets up an nginx vhost that serves directory listings (autoindex on) directly
from [% install_dir %]/[% domain %].

Useful for public file distribution, download mirrors, or static media serving
where directory browsing is desired rather than application proxying.

Shares the same kernel/nginx global tuning as nginxproxy (sysctl backlog,
worker_connections, server_names_hash_bucket_size).

=cut

sub required_recipes {
    return (
        nginx => sub { () },
    );
}

sub args {
    return (
        properties => {
            ipv6 => { type => 'boolean', default => 1 },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'nginxdirindex.domain.conf.tt' => 'nginxdirindex.domain.conf',
    );
}

sub tests {
    return qw{nginxdirindex.tt};
}

1;
