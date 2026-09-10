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

=head2 Surviving a rebuild

C</var/lib/redis> is salvaged off a running guest and put back on the one that
replaces it, so a redis holding anything more than a cache comes up with the
keyspace it had rather than an empty one.

That costs something worth saying out loud.  The package leaves the directory
C<redis:redis> 0750, so the fragment gives it the admin user as its group and
sets the setgid bit so the files redis writes afterwards land in that group too:
the keyspace is readable from here on by whoever holds the admin account, and
goes into the data directory and into any backup taken of it.

B<That is no longer needed for the salvage.>  The fetch reads the guest as root
now, so a directory redis keeps to itself comes off it whatever the group says.
Taking the widening out is issue #98, one recipe at a time and each on a guest,
because setgid on a directory a service writes into for the rest of its life is
not something to remove without watching it start again.  A guest where redis is
only a cache pays none of that and should say C<save: 0>, which turns
persistence off and leaves nothing to salvage.

Putting it back is the fiddly end.  redis is installed and started by cloud-init
long before any fragment runs, so it owns the destination before there is
anything to restore into it; the fragment stops it, works out whether what is
there is real state or the empty snapshot the stop just wrote, and restarts it
afterwards.  C<templates/redis.global.tt> says how, at length.

=cut

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
    my ( $self, %opts ) = @_;

    # Clients hold connections open rather than opening one per operation, so
    # even a busy application opens few a second.
    #
    # On the configured port, not on 6379.  This named the default outright, so
    # a guest that moved redis had the limit applied to a port nothing was
    # listening on and none at all on the port it had actually been given.
    return ( ( $opts{port} // 6379 ) => 512 );
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

        # The ufw application profile for the port this guest configured.  It
        # lived under ufw, where the port is not knowable: a recipe hands ufw
        # its rate_limits and nothing else.
        'redis.ufw.conf.tt' => 'redis_ufw.conf',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # The RDB and the AOF: whatever redis was being used for beyond a cache, and
    # the only thing about a redis guest that cannot be built again out of the
    # configuration.  Naming it here is half the job and the half that is
    # invisible when the other half is missing -- see the long comment in
    # templates/redis.global.tt, which is what makes this directory readable to
    # the account the fetch runs as, and what puts the contents back on a guest
    # that has just been rebuilt.
    return (
        '/var/lib/redis/' => 'redis/',
    );
}

sub tests {
    return qw{redis.tt};
}

1;
