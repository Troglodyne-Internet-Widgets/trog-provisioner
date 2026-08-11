package Provisioner::Recipe::mariadb;

use 5.041;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::mariadb

=head2 SYNOPSIS

    somedomain:
        mariadb:
            dump: path/to/dump/in/datadir
            version:
            root_pw: blahblah

=head2 DESCRIPTION

Set up the specified mariadb version and install the provided dump.
Secures the DB and sets the root pw as specified.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{mariadb-client libmariadb-dev-compat libmariadb-dev mariadb-backup libaio-dev pigz};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        required   => [qw{root_pw dumpfile version}],
        properties => {
            root_pw  => { type => 'string' },
            dumpfile => { type => 'string' },
            # TODO fetch latest mariadb version by default
            version  => { type => 'string' },
        },
    );
}

sub template_files {
    my ($self) = @_;

    return (
        'mysql.secure_installation.tt' => 'secure_installation.sql',
        'my.cnf.tt'                    => 'my.cnf',
        'mysql.service.tt'             => 'mariadb.service',
        'mariadb.backup.sh.tt'         => 'mariadb-backup.sh',
        'mariadb.backup.cron.tt'       => 'mariadb-backup.cron',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/mysql/' => 'mysql/',
    );
}

sub tests {
    return qw{mariadb.tt};
}

1;
