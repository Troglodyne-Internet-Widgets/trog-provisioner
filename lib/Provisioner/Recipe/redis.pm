package Provisioner::Recipe::redis;

use strict;
use warnings;

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

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{redis-server};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    $opts{bind}  //= '127.0.0.1';
    $opts{port}  //= 6379;
    $opts{save}  //= 1;

    if ( defined $opts{maxmemory_policy} ) {
        my %valid_policies = map { $_ => 1 } qw{
            noeviction allkeys-lru volatile-lru allkeys-random
            volatile-random volatile-ttl allkeys-lfu volatile-lfu
        };
        die "Invalid maxmemory_policy '$opts{maxmemory_policy}'"
            unless $valid_policies{ $opts{maxmemory_policy} };
    }

    return %opts;
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

1;
