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

=head3 Where it comes from, and why not the bintar

From MariaDB's own apt repository for that exact release --
C<archive.mariadb.org/mariadb-E<lt>versionE<gt>/repo/ubuntu> -- pinned above
1000 so apt will downgrade to it where Ubuntu ships something newer.

It used to be the generic Linux bintar from the same archive, which pins just as
exactly and costs something that is not obvious from reading it: that tarball is
built against libaio, so InnoDB cannot use io_uring however the guest is
configured. Measured on a guest -- no C<liburing> in C<mariadbd>'s C<NEEDED>, no
io_uring descriptors while running. It is also why the installer used to symlink
C<libaio.so.1t64> to C<libaio.so.1>, a soname noble renamed in the 64-bit
C<time_t> transition and the bintar still asks for.

The repository builds are Debian's, so C<mariadb-server-core> there depends on
C<liburing2>, and the packaging brings its own datadir, unit and socket rather
than this recipe hand-rolling a layout under F</opt>.

B<The constraint that comes with it>: a per-release repository exists only for
distributions that existed when that release was made. C<11.4.4> and C<10.11.10>
have C<noble>; C<10.11.7> and older do not. C<install_mariadb.sh> checks before
it commits and fails naming the distributions that release does have, rather
than letting C<apt-get update> 404 three steps later.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # Not the mariadb packages: cloud-init installs these before the
        # makefile runs, so asking for them here gets Ubuntu's version
        # installed and then downgraded.  install_mariadb.sh takes the whole
        # set from the pinned repository in one go.  pigz is the backup
        # script's.
        return qw{pigz};
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
            version => { type => 'string', pattern => '^[0-9]+[.][0-9]+[.][0-9]+$' },

            # No `user` here any more.  It existed to name the group
            # /opt/mysql was chowned to so the admin could read the datadir;
            # the packaged datadir is 0700 mysql:mysql, which is right, and
            # anybody who needs the database has sudo and the socket.
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # The password goes inside a single-quoted SQL string literal, and one that
    # contains a quote or a backslash would end it early -- which is a syntax
    # error on a good day and something else on a bad one.
    ( $opts{root_pw_sql} = $opts{root_pw} // q{} ) =~ s/(['\\])/\\$1/g;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'mysql.secure_installation.tt' => 'secure_installation.sql',
        'my.cnf.tt'                    => 'mariadb-provisioner.cnf',
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
