package Provisioner::Recipe::mariadb;

#ABSTRACT: Set up MariaDB, and put back the databases the last guest had.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::mariadb

=head2 SYNOPSIS

    somedomain:
        mariadb:
            dumpfile: path/to/dump/in/datadir
            version: 11.4.4
            root_pw: blahblah

=head2 DESCRIPTION

Installs the configured MariaDB version.  Restores the databases of the guest
that this one replaces.  A domain that never had a database starts from the
configured dump.  Secures the server and sets the root password to C<root_pw>.

=head3 What a rebuild keeps

The nightly backup writes C</var/backups/mysql/E<lt>timestampE<gt>/E<lt>databaseE<gt>/>.
C<remote_files> fetches that whole tree into the data directory.  The C<data>
recipe puts it back on the new guest under C<install_dir/domain/mysql>.  Then
C<mariadb-restore.sh> imports the newest finished dump.

So C<dumpfile> is a B<seed>, not the thing that a rebuild loads.  A domain with
no database yet starts from it.  It loads only into a server that has no
databases, and only when there is no salvaged dump.

This recipe never loads a dump over a database that already exists.
C<scripts/restore_state> applies the same rule to files.  When you provision a
running guest again, the salvage is a copy of its own databases, fetched
minutes before.  If that fetch was incomplete, a restore over the original
replaces the real data with part of it.  So a rebuilt server, which has none of
the databases, gets all of them.  A live server, which has all of them, gets
nothing.

A dump is restorable when it contains the file C<complete>, which the backup
writes last.  A dump without that file is not restored.  If an operator knows
that such a dump is whole, they can C<touch> the file.

The accounts also come back, from C<grants.sql.gz>.  The restore skips C<root>
and the accounts of the server itself, because C<root_pw> is configuration.  A
salvaged C<GRANT> for root carries the password hash of the old guest.  The
C<.my.cnf> files for root and the admin hold C<root_pw>, and the two must agree.

=head3 What C<root_pw> is for

C<root_pw> is not for remote access.  The drop-in sets C<skip_networking>, so
the server listens only on its socket.  Root authenticates by
C<unix_socket OR mysql_native_password>.  The password lets something connect
as the database root over that socket B<without being root on the guest>.
Examples are an application, or an operator with a shell as another user.  Root
on the guest needs no password, and the backup cron and everything else here
depend on that.

=head3 Who can connect, and with what

This recipe writes a C<.my.cnf> for three accounts.  Clients read C<~/.my.cnf>
without being told to, and recipes outside this repository point
C<--defaults-file> at one:

=over 4

=item * C<root> and the admin user get full access, as the database C<root>
with C<root_pw>.  The admin has sudo and can reach the socket anyway.  The file
makes C<--defaults-file> work for the admin.

=item * The service user gets the socket and its own name, and B<no password>.
The dump or another recipe decides what that account can do.  This file only
gives those grants an account to apply to.  If the service user is the admin
user, it gets the admin file instead.

=back

Each file is mode 0600 and owned by the account that it belongs to.  Every
section names the socket, because C<--defaults-file> replaces the defaults and
does not add to them.

=head3 Where it comes from

The packages come from the MariaDB apt repository for that exact release,
C<archive.mariadb.org/mariadb-E<lt>versionE<gt>/repo/ubuntu>.  Its pin priority
is above 1000, so apt downgrades to it when Ubuntu ships a newer version.  The
datadir, unit and socket are the package's.  This recipe adds one drop-in under
F</etc/mysql/mariadb.conf.d> and nothing else.

B<A release has a repository only for the distributions that existed when it
was made.>  C<11.4.4> and C<10.11.10> have C<noble>.  C<10.11.7> and older do
not.  If you ask for one of those on a noble guest, the build fails and names
the distributions that the release has.  There is no fallback.  A different
version cannot restore the binlogs, and the pin exists for them.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{root_pw dumpfile version}],
        properties => {
            root_pw => { type => 'string' },

            # A seed, not what a rebuild loads.  See "What a rebuild keeps" above.
            dumpfile => { type => 'string' },

            # TODO fetch latest mariadb version by default
            # A full release, not a series.  MariaDB publishes a repository per
            # release, so "10.11" names no repository.
            version => { type => 'string', pattern => '^[0-9]+[.][0-9]+[.][0-9]+$' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # The password goes inside a single-quoted SQL string.  A quote or a
    # backslash ends the string early, which is a syntax error or an injection.
    ( $opts{root_pw_sql} = $opts{root_pw} // q{} ) =~ s/(['\\])/\\$1/g;

    # An option file double-quotes the value, so there a double quote or a
    # backslash ends it early.
    ( $opts{root_pw_cnf} = $opts{root_pw} // q{} ) =~ s/(["\\])/\\$1/g;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'mysql.secure_installation.tt'  => 'secure_installation.sql',
        'mariadb.provisioner.cnf.tt'    => 'mariadb-provisioner.cnf',
        'mariadb.client.cnf.tt'         => 'mariadb-client.cnf',
        'mariadb.client.service.cnf.tt' => 'mariadb-client-service.cnf',
        'mariadb.backup.sh.tt'          => 'mariadb-backup.sh',
        'mariadb.backup.cron.tt'        => 'mariadb-backup.cron',
        'mariadb.restore.sh.tt'         => 'mariadb-restore.sh',
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Returns C<mariadb-backup.sh>, which the guest runs before the fetch.  The cron
runs it at 2:30 each night, so without this call a rebuild loses every write
since then.

=cut

sub remote_prepare {
    return ('/usr/local/sbin/mariadb-backup.sh');
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

Salvages F</var/backups/mysql/> into C<mysql/> in the data directory.  Those
dumps are the only state of this server that nothing here can regenerate.
C<mariadb-restore.sh> imports them again.  See L</What a rebuild keeps> and
L<Provisioner::Recipe/Naming a path is not enough>.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/mysql/' => 'mysql/',
    );
}

sub tests {
    return qw{mariadb.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

C<archive.mariadb.org>, the apt repository of the packages.  It is a
third-party repository, so the cache serves it, not the mirrorlist of
L<Provisioner::Recipe::aptmirror>.  The signing key comes from C<mariadb.org>,
which F<bin/new_config> fetches, and the guest does not.

=cut

sub fetch_hosts {
    return qw{archive.mariadb.org};
}

=head2 @classes = $recipe->cache_classes()

The apt classes for C<archive.mariadb.org>, where the packages come from.

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->apt_repo_classes('archive.mariadb.org');
}

1;
