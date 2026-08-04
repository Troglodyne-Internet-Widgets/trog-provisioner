package Provisioner::Recipe::mariadb;

use strict;
use warnings;

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

sub validate {
    my ( $self, %opts ) = @_;

    my $rpw = $opts{root_pw};
    die "Must define root_pw ns in [mariadb] section of recipes.yaml" unless $rpw;

    my $dump = $opts{dumpfile};
    die "Must define dumpfile in [mariadb] section of recipes.yaml" unless $dump;

    my $ver = $opts{version};
    die "Must define version in [mariadb] section of recipes.yaml" unless $ver;

    return %opts;
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
