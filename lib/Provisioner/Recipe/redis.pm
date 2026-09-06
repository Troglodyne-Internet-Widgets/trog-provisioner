package Provisioner::Recipe::redis;

#ABSTRACT: Install and configure Redis.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::redis

=head2 SYNOPSIS

    somedomain:
        redis:
            bind: 127.0.0.1
            port: 6379
            requirepass: secretpassword
            maxmemory: 256mb
            maxmemory_policy: allkeys-lru

=head2 DESCRIPTION

Installs and configures Redis from the standard distribution packages.
Defaults to binding on 127.0.0.1 (local only). Set bind to a routable
address and add the ufw recipe to expose the port.

Optional parameters:
- bind: IP to listen on (default: 127.0.0.1)
- port: port number (default: 6379)
- requirepass: authentication password
- maxmemory: memory limit e.g. 256mb, 1gb
- maxmemory_policy: eviction policy when maxmemory is hit (default: noeviction)
- save: set to 0 to disable RDB persistence (pure cache mode)

Configuration goes in as a fragment under C</etc/redis/redis.conf.d>, which
C<configd> merges into C<redis.conf> every time redis-server starts or reloads.
The package's own C<redis.conf> becomes C<00-original> and keeps applying
wherever nothing above says otherwise, so anything this recipe has no opinion
about is still whatever Debian chose rather than absent. The C<configd> recipe
is pulled in for that; see L<Provisioner::Recipe::configd>.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{redis-server};
    }
    die "Unsupported packager";
}

sub required_recipes {
    my ( $self, %opts ) = @_;

    # redis.conf has no conf.d, and its `include` is not one: the included file
    # has to be named from the file doing the including, and a glob is a fatal
    # error.  configd generates redis.conf from a fragment directory instead,
    # which is what leaves the distribution's own redis.conf in place underneath
    # what this recipe decided.
    return (
        configd => sub { return ( languages => ['redis'] ) },
        $self->SUPER::required_recipes(%opts),
    );
}

sub rate_limits {

    # Clients hold connections open rather than opening one per operation, so
    # even a busy application opens few a second.
    return ( 6379 => 512 );
}

sub args {
    return (
        type       => 'object',
        properties => {
            bind             => { type => 'string',  default => '127.0.0.1' },
            port             => { type => 'integer', minimum => 1024, default => 6379 },
            save             => { type => 'boolean', default => 1 },
            requirepass      => { type => 'string' },
            maxmemory        => { type => 'string' },
            maxmemory_policy => {
                type => 'string',
                enum => [
                    qw{
                      noeviction allkeys-lru volatile-lru allkeys-random
                      volatile-random volatile-ttl allkeys-lfu volatile-lfu
                    }
                ],
            },
        },
    );
}

sub template_files {
    return (
        'redis.conf.tt' => 'redis.conf',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/lib/redis/' => 'redis/',
    );
}

sub tests {
    return qw{redis.tt};
}

1;
