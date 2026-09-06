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

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # The mariadb packages are deliberately absent: cloud-init installs
        # deps before the makefile runs, so naming them here would install
        # Ubuntu's and leave the pin to downgrade them.  install_mariadb.sh
        # takes the set from the pinned repository instead.  pigz is the backup
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
