package Provisioner::Recipe::postgres;

#ABSTRACT: Set up PostgreSQL and load the provided dump.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::postgres

=head2 SYNOPSIS

    somedomain:
        postgres:
            dumps:
                - path/to/dump/in/datadir

=head2 DESCRIPTION

Set up the latest postgres available and loads the provided dump.
It is your responsibility to make sure the dump file has CREATE DATABSE statements, etc.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{postgresql-common postgresql-common-dev pigz};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        properties => {
            dumps => {
                type => 'array',
                items => { type => "string" },
            },
        },
    );
}

sub template_files {
    return (
        'postgres.backup.sh.tt'   => 'postgres-backup.sh',
        'postgres.backup.cron.tt' => 'postgres-backup.cron',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/postgres/' => 'postgres/',
    );
}

sub tests {
    return qw{postgres.tt};
}

1;
