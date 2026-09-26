package Provisioner::Recipe::postgres;

#ABSTRACT: Set up PostgreSQL, and put back the databases the last guest had.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::postgres

=head2 SYNOPSIS

    somedomain:
        postgres:
            dumps:
                - path/to/dump/in/datadir

=head2 DESCRIPTION

This recipe installs the newest postgres in the apt repository of the
PostgreSQL project, or the major version that C<version> names.
L<Provisioner::Recipe::Ubuntu::postgres> says how it finds the newest.  It puts back
the databases that the replaced guest had.  If a domain never had a database,
it loads the configured dumps instead.

=head3 What a rebuild keeps

The nightly backup writes C</var/backups/postgres/E<lt>timestampE<gt>/>.  Each
of these holds the roles and a directory-format dump for each database.
C<remote_files> fetches that tree into the data directory.  The C<data> recipe
then puts it on the new guest under C<install_dir/domain/postgres>.
C<postgres-restore.sh> imports it from there, and uses the newest finished dump.

So C<dumps> is a B<seed>, not the thing that a rebuild loads.  A domain with no
database yet starts from it.  You must make sure that each such file has its own
C<CREATE DATABASE> statements, because nothing else makes the database.  The
restore loads the seeds only when it restored nothing from a salvaged dump, and
only into a cluster that has no databases.

The restore never loads a dump over a database that is already there.  This is
the rule of C<scripts/restore_state>, one level down.  When you re-provision a
running guest, the fetch of its databases happens minutes earlier.  If that
fetch is short, a write back over the original replaces the real data with the
part that was readable.  So a rebuilt cluster, which has none of the databases,
gets all of them.  A live cluster, which has all of them, gets nothing.

A dump is restorable when it holds the file C<complete>, which the backup writes
last.  The restore skips a dump without that file.  If you know that such a dump
is whole, C<touch> its C<complete> file.

=cut

=head2 @claims = $recipe->listens()

5432, where the packaged configuration listens, on 127.0.0.1.  It listens on
C<localhost>, and on Ubuntu that name is only 127.0.0.1.

=cut

sub listens {
    return qw{127.0.0.1:5432};
}

sub args {
    return (
        type       => 'object',
        properties => {

            # Seeds for a domain with no database yet.  A salvaged dump wins
            # over them.  See "What a rebuild keeps".
            dumps => {
                type  => 'array',
                items => { type => "string" },
            },

            version => { type => 'integer', minimum => 1, description => 'The major version of postgres to install, such as 16.  Unset installs the newest one the PGDG repository offers.' },
        },
    );
}

sub template_files {
    return (
        'postgres.backup.sh.tt'   => 'postgres-backup.sh',
        'postgres.backup.cron.tt' => 'postgres-backup.cron',
        'postgres.restore.sh.tt'  => 'postgres-restore.sh',
    );
}

=head3 @commands = $recipe->remote_prepare($install_dir, $domain)

Returns the backup script, so the guest takes a fresh dump just before the fetch.
The nightly dump is up to a day old, and a rebuild loses what changed since.

=cut

sub remote_prepare {
    return ('/usr/local/sbin/postgres-backup.sh');
}

=head3 %files = $recipe->remote_files($install_dir, $domain)

Returns the backup directory on the guest, mapped to C<postgres/> in the data
directory.  These dumps are the only thing in the cluster that nothing here can
make again.  See L</What a rebuild keeps> for what imports them.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/postgres/' => 'postgres/',
    );
}

sub tests {
    return qw{postgres.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

C<apt.postgresql.org>, the apt repository of the PostgreSQL project.

=cut

sub fetch_hosts {
    return qw{apt.postgresql.org};
}

=head2 @classes = $recipe->cache_classes()

The classes for that apt repository.  See C<apt_repo_classes> in
L<Provisioner::Recipe>.

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->apt_repo_classes('apt.postgresql.org');
}

1;
