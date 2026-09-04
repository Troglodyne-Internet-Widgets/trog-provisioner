package Provisioner::Recipe::mariadb;

#ABSTRACT: Set up MariaDB and load the provided dump.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
            # A full release, not a series: archive.mariadb.org publishes a
            # bintar per release, so "10.11" is a 404 that only shows up as tar
            # refusing the error page curl saved in its place.
            version  => { type => 'string', pattern => '^[0-9]+[.][0-9]+[.][0-9]+$' },
            # The group /opt/mysql is chowned to, so the admin can read it.
            # The template has always used this and nothing ever declared it,
            # so it rendered empty -- and an empty word is no word at all to a
            # shell, so install_mariadb.sh got the version as its $client, the
            # dump path as its $version, and fetched
            # archive.mariadb.org/mariadb-/opt/domains/<dom>/dump.sql/...
            user     => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Nothing that pulls this recipe in supplies a user, and the admin owns
    # everything else on the guest.  Same as perl and nvm do with this field.
    $opts{user} //= $opts{admin_user};

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
