package Trog::SQLite;

#ABSTRACT: A database handle with the schema already applied.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use DBI();

# Named so that a missing driver fails here and not inside DBI->connect.
# Nothing calls it.
use DBD::SQLite();    ## no critic (ProhibitUnusedImports)
use File::Slurper();

=head1 NAME

Trog::SQLite - a database handle with the schema already applied

=head1 SYNOPSIS

    my $dbh = Trog::SQLite::dbh( "$checkout/schema/ips.sql", '/etc/trog-provisioner/ips.db' );

=head1 DESCRIPTION

This code comes from tCMS, so a database opened here behaves the same as one
opened there.  The pragmas make two provisions that run at the same time wait
for each other.  Without WAL and a busy timeout, one of them gets
C<database is locked>.

=head2 dbh($schema, $dbname)

Returns a handle to C<$dbname>.  If you give C<$schema>, the DDL in that file is
applied first.  Omit C<$schema> for a database that already has its schema.

The handle is cached for the rest of the process.  A second call for the same
C<$dbname> returns the cached handle and does not apply C<$schema> again.

Dies if the connection fails, if the schema cannot be read or applied, or if one
of the pragmas fails.

Do not call this during C<BEGIN> or outside a sub.  A handle must not outlive a
fork, so a forked child calls C<forget> before it calls this.

=cut

# The handle cache, keyed by database file.  A forked child inherits it.
my $dbh = {};

sub dbh {
    my ( $schema, $dbname ) = @_;
    return $dbh->{$dbname} if $dbh->{$dbname};

    # No touch first, because DBD::SQLite creates the file on connect.
    my $db = DBI->connect( "dbi:SQLite:dbname=$dbname", q{}, q{}, { RaiseError => 1, PrintError => 0 } );

    if ($schema) {

        # No test first, because read_text dies with the path and the errno.
        my $qq = File::Slurper::read_text($schema);
        $db->{sqlite_allow_multiple_statements} = 1;
        $db->do($qq) or die "Could not ensure database consistency: " . $db->errstr;
        $db->{sqlite_allow_multiple_statements} = 0;
    }

    $dbh->{$dbname} = $db;

    $db->do("PRAGMA foreign_keys = ON")    or die "Could not enable foreign keys";
    $db->do("PRAGMA journal_mode = WAL")   or die "Could not enable WAL mode";
    $db->do("PRAGMA synchronous = NORMAL") or die "Could not enable sync mode normal";
    $db->do("PRAGMA busy_timeout = 5000")  or die "Could not set busy_timeout";

    return $db;
}

=head2 forget()

Drops the cached handles and returns 1.  A forked child calls this so that it
opens its own handle and does not use the handle of its parent.

=cut

sub forget {
    $dbh = {};
    return 1;
}

1;
