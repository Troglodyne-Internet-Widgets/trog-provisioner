package Provisioner::Recipe::redis;

#ABSTRACT: Install and configure Redis.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

Installs and configures Redis from the packages of the distribution.  By
default it binds to 127.0.0.1, so only the guest can connect.  To expose the
port, set C<bind> to a routable address and add the ufw recipe.

All parameters are optional:

=over 4

=item C<bind>

The IP address to listen on.  The default is 127.0.0.1.

=item C<port>

The port number.  The default is 6379.

=item C<requirepass>

The password that clients authenticate with.

=item C<maxmemory>

The memory limit, for example C<256mb> or C<1gb>.

=item C<maxmemory_policy>

The eviction policy when redis reaches C<maxmemory>.  The default is
C<noeviction>.

=item C<save>

Set it to 0 to turn off RDB persistence, for a pure cache.

=back

The configuration goes in as a fragment under C</etc/redis/redis.conf.d>.
C<configd> merges the fragments into C<redis.conf> each time redis-server
starts or reloads.  The C<redis.conf> of the package becomes C<00-original>.
It still applies wherever no later fragment sets a value.  So each setting that
this recipe does not set keeps the value that Debian chose.  This recipe pulls
in the C<configd> recipe for this.  See L<Provisioner::Recipe::configd>.

=head2 Surviving a rebuild

bin/new_config salvages C</var/lib/redis> from a running guest, and the fragment
puts it back on the guest that replaces it.  So a redis that holds more than a
cache comes up with its keyspace, not an empty one.

The fetch reads the guest as root.  So the package default for the directory,
C<redis:redis> 0750, is enough, and the fragment keeps it.  C<restore_state>
leaves what it moves owned by the user that ran the fetch, not by redis.  So
the fragment changes the owner back to C<redis:redis>.

If redis is only a cache on a guest, set C<save: 0>.  That turns persistence off
and leaves nothing to salvage.

The restore is the difficult part.  cloud-init installs and starts redis before
any fragment runs.  So the fragment stops redis and then finds out whether the
directory holds real state.  The alternative is the empty snapshot that the stop
wrote.  After the restore, the fragment starts redis again.
C<templates/ubuntu/redis.global.tt> has the details.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # redis has no conf.d, so configd makes redis.conf from a fragment
    # directory.  templates/ubuntu/redis.global.tt says why.
    return (
        configd => sub { return ( languages => ['redis'] ) },
        $self->SUPER::required_recipes(%opts),
    );
}

sub rate_limits {
    my ( $self, %opts ) = @_;

    # Clients keep connections open and do not open one per operation.  So even
    # a busy application opens few connections each second.
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

        # The ufw application profile for the configured port.  It is here
        # because a recipe gives ufw only its rate_limits, not its port.
        'redis.ufw.conf.tt' => 'redis_ufw.conf',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    # The RDB and the AOF.  They are the only part of a redis guest that the
    # configuration cannot build again.  This names them for the salvage.
    # templates/ubuntu/redis.global.tt puts them back on a rebuilt guest.
    return (
        '/var/lib/redis/' => 'redis/',
    );
}

sub tests {
    return qw{redis.tt};
}

1;
