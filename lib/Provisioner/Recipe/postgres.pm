package Provisioner::Recipe::postgres;

#ABSTRACT: Set up PostgreSQL, and put back the databases the last guest had.

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

Set up the latest postgres available, put back whatever the guest this one
replaces had in it, and fall back to the configured dumps for a domain that has
never had a database.

=head3 What a rebuild keeps

The nightly backup writes C</var/backups/postgres/E<lt>timestampE<gt>/>, holding
the roles and a directory-format dump per database. C<remote_files> brings that
tree down into the data directory and the C<data> recipe puts it back on the new
guest under C<install_dir/domain/postgres>. The leg that was missing is the last
one: C<postgres-restore.sh> imports it, newest finished dump first.

Which makes C<dumps> a B<seed> rather than the thing that is loaded. It is what a
domain with no database yet starts from -- and it is your responsibility to make
sure such a file has its own C<CREATE DATABASE> statements, since nothing else
will make one. It is loaded only into a cluster with nothing in it, and only when
there is no salvaged dump to prefer, because loading it every provision was how a
rebuild came up holding a snapshot somebody wrote once and none of what had
happened since.

Nothing is ever loaded over a database that is already there, which is
C<scripts/restore_state>'s rule one level down: re-provisioning a running guest
fetched that guest's own databases minutes earlier, and writing a fetch that came
up short back over the original would replace the real thing with the half of it
that could be read. So a rebuilt cluster, which has none of them, gets all of it;
a live one, which has all of them, gets nothing.

A dump counts as restorable when it says it finished -- C<complete>, which the
backup writes last. A dump taken before the backup learned to say so has no such
file and will not be restored; an operator who knows one is whole can C<touch>
it.

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # The seeds a domain with no database of its own starts from, rather
            # than the things a rebuild loads: what this guest actually had is
            # salvaged, and beats them.
            dumps => {
                type  => 'array',
                items => { type => "string" },
            },
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

# The dumps the nightly backup wrote, which is everything this cluster has that
# nothing here can regenerate.  What imports them again is postgres-restore.sh --
# see L</What a rebuild keeps>, and Provisioner::Recipe's remote_files, which is
# only half a round trip until a fragment does something with what it names.
# The same reason mariadb has one: the nightly dump is a night old, and the
# difference is what a rebuild would lose.
sub remote_prepare {
    return ('/usr/local/sbin/postgres-backup.sh');
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
