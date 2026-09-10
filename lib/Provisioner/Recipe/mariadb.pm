package Provisioner::Recipe::mariadb;

#ABSTRACT: Set up MariaDB, and put back the databases the last guest had.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::mariadb

=head2 SYNOPSIS

    somedomain:
        mariadb:
            dumpfile: path/to/dump/in/datadir
            version: 11.4.4
            root_pw: blahblah

=head2 DESCRIPTION

Set up the specified mariadb version, put back whatever the guest this one
replaces had in it, and fall back to the configured dump for a domain that has
never had a database. Secures the DB and sets the root pw as specified.

=head3 What a rebuild keeps

The nightly backup writes C</var/backups/mysql/E<lt>timestampE<gt>/E<lt>databaseE<gt>/>,
C<remote_files> brings that whole tree down into the data directory, and the
C<data> recipe puts it back on the new guest under
C<install_dir/domain/mysql>. The leg that was missing is the last one:
C<mariadb-restore.sh> imports it, newest finished dump first.

Which makes C<dumpfile> a B<seed> rather than the thing that is loaded. It is
what a domain with no database yet starts from, and it is loaded only into a
server with nothing in it and only when there is no salvaged dump to prefer --
because loading it every provision was how a rebuild came up holding a snapshot
somebody wrote once and none of what had happened since.

Nothing is ever loaded over a database that is already there, which is
C<scripts/restore_state>'s rule one level down: re-provisioning a running guest
fetched that guest's own databases minutes earlier, and writing a fetch that came
up short back over the original would replace the real thing with the half of it
that could be read. So a rebuilt server, which has none of them, gets all of it;
a live one, which has all of them, gets nothing.

A dump counts as restorable when it says it finished -- C<complete>, which the
backup writes last. A dump taken before the backup learned to say so has no such
file and will not be restored; an operator who knows one is whole can C<touch>
it.

The accounts come back too, out of C<grants.sql.gz>, minus C<root> and the
server's own: C<root_pw> is configuration, and a salvaged C<GRANT> putting the
last guest's hash back would leave all three C<.my.cnf> files this recipe writes
claiming a password the server no longer has.

=head3 What C<root_pw> is for

Not remote access: the drop-in sets C<skip_networking>, so the server listens on
nothing but its socket. Root is C<unix_socket OR mysql_native_password>, so the
password is how something authenticates as root over that socket B<without being
root on the box> -- an application, or an operator who has a shell as somebody
else. Being root on the guest needs no password at all, which is what the backup
cron and everything else here relies on.

=head3 Who can connect, and with what

A C<.my.cnf> is written for three accounts, because clients read C<~/.my.cnf>
without being told to and because recipes outside this repository point
C<--defaults-file> at one:

=over 4

=item * C<root> and the admin user get full access, as the database's C<root>
with C<root_pw>. The admin has sudo and could reach it over the socket anyway;
this is what makes C<--defaults-file> work for them.

=item * The service user gets the socket and its own name and B<no password>.
What that account may do is the dump's business, or another recipe's -- this
only gives whatever grants it later somewhere to land.

=back

All three are 0600 and owned by the account they belong to. Every section names
the socket, because C<--defaults-file> replaces the defaults rather than adding
to them.

=head3 Where it comes from

MariaDB's own apt repository for that exact release,
C<archive.mariadb.org/mariadb-E<lt>versionE<gt>/repo/ubuntu>, pinned above 1000
so apt will downgrade to it where Ubuntu ships something newer. The datadir,
unit and socket are the package's; this recipe adds a drop-in under
F</etc/mysql/mariadb.conf.d> and nothing else.

B<A release only has a repository for the distributions that existed when it was
made.> C<11.4.4> and C<10.11.10> have C<noble>; C<10.11.7> and older do not, and
asking for one of those on a noble guest fails the build naming what that
release does have. There is no fallback: an approximate version would restore no
binlogs, which is what the pinning is for.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{root_pw dumpfile version}],
        properties => {
            root_pw => { type => 'string' },

            # The seed a domain with no database of its own starts from, rather
            # than the thing a rebuild loads: what this guest actually had is
            # salvaged, and beats it.
            dumpfile => { type => 'string' },

            # TODO fetch latest mariadb version by default
            # A full release, not a series: the repository is published per
            # release, so "10.11" names nothing.
            version => { type => 'string', pattern => '^[0-9]+[.][0-9]+[.][0-9]+$' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # The password goes inside a single-quoted SQL string literal, and one that
    # contains a quote or a backslash would end it early -- which is a syntax
    # error on a good day and something else on a bad one.
    ( $opts{root_pw_sql} = $opts{root_pw} // q{} ) =~ s/(['\\])/\\$1/g;

    # And again for an option file, where the rules are its own: the value is
    # double-quoted, so a double quote or a backslash is what ends it early.
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

# The dumps the nightly backup wrote, which is everything this server has that
# nothing here can regenerate.  What imports them again is mariadb-restore.sh --
# see L</What a rebuild keeps>, and Provisioner::Recipe's remote_files, which is
# only half a round trip until a fragment does something with what it names.
# A dump taken now.  The cron runs at half two, so a salvage without this is
# every write since then, and the restore below would put the guest back to
# whenever that was.
sub remote_prepare {
    return ('/usr/local/sbin/mariadb-backup.sh');
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
