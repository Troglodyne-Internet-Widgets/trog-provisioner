package Provisioner::Recipe::nginxdirindex;

#ABSTRACT: Serve browsable directory listings over nginx.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginxdirindex

=head2 SYNOPSIS

    somedomain:
        nginxdirindex:
            ipv6: true

=head2 DESCRIPTION

Set up an nginx vhost that serves directory listings (autoindex on) directly
from C<install_dir/domain>.

Use it for public file distribution, download mirrors, or static media, where
you want directory browsing and no application behind a proxy.

It requires L<Provisioner::Recipe::nginx>, which does the global tuning of the
kernel and nginx (sysctl backlog, worker_connections,
server_names_hash_bucket_size).

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

            # Also in the nginx recipe, because a recipe renders with only its own
            # configuration.  Keep it equal to that one: somaxconn comes from it.
            backlog => { type => 'integer', default => 32768, minimum => 0 },
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
