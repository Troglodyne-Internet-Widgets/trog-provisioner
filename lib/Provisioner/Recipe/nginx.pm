package Provisioner::Recipe::nginx;

#ABSTRACT: Install nginx and its global configuration.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginx

=head2 SYNOPSIS

    somedomain:
        nginx:
            backlog: 32768

=head2 DESCRIPTION

Install nginx, set the kernel backlog and worker_connections to C<backlog>, and
install the global configuration of nginx.

=head2 USE AS DEPENDENCY

Use this recipe as a dependency of other nginx recipes, not on its own.

=cut

sub rate_limits {

    # One page load opens dozens of connections to one origin, and a shared NAT
    # multiplies that by each user behind it.  A thousand a second is not a visitor.
    return ( 80 => 1024, 443 => 1024 );
}

=head2 @names = $recipe->subdomains()

C<www>, which the vhost this writes answers for: it serves the domain and every
alias, and www is an alias rather than a name of its own.

Every domain in the map used to be given this whether or not it ran a web
server.  A domain that serves nothing over HTTP has no use for the name, and a
certificate covering one nothing answers on is a name somebody has to explain.

=cut

sub subdomains {
    return qw{www};
}

sub args {
    return (
        properties => {
            backlog => { type => 'integer', default => 32768, minimum => 0 },

            # A domain name is at most 253 characters.  256 is the next multiple
            # of the cache line size, which nginx aligns this value to.
            server_names_hash_bucket_size => { type => 'integer', default => 256, minimum => 32 },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt' => 'nginx.global.conf',
        'nginx.sysctl.conf.tt' => 'nginx.sysctl.conf',

        #XXX TODO: remove this, because bin/new_config copies openssl.conf over it (#221).
        'openssl.tt' => 'openssl.conf',
    );
}

sub tests {
    return qw{nginx.tt};
}

1;
