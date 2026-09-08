package Trog::SQLite;

#ABSTRACT: A database handle with the schema already applied.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use DBI();

# Named so the dependency is declared and a missing driver fails here rather
# than inside DBI->connect with a less obvious message.  Nothing calls it.
use DBD::SQLite();    ## no critic (ProhibitUnusedImports)
use File::Slurper();

=head1 NAME

Trog::SQLite - a database handle with the schema already applied

=head1 SYNOPSIS

    my $dbh = Trog::SQLite::dbh( "$checkout/schema/ips.sql", '/etc/trog-provisioner/ips.db' );

=head1 DESCRIPTION

Lifted from tCMS, which has been running it for years, so that a database
opened here behaves the way one opened there does.  The pragmas are the point:
without WAL and a busy timeout, two provisions running at once meet
C<database is locked> rather than waiting for each other.

=head2 dbh($schema, $dbname)

A handle to C<$dbname>, with the DDL in C<$schema> applied first and the
handle cached for the rest of the process.  C<$schema> may be omitted for a
database somebody else set up.

Dies if the schema cannot be read or applied.

B<Do not call this during C<BEGIN>, or outside a sub.>  The handle must not
outlive a fork, and the usual SQLite fork-safety concerns apply.

=cut

# Different across forks, and consistent within them.
my $dbh = {};

sub dbh {
    my ( $schema, $dbname ) = @_;
    $dbh //= {};
    return $dbh->{$dbname} if $dbh->{$dbname};

    # No touch first: DBI:SQLite creates the file on connect.  It also cannot
    # simply be made unconditional, as that would bump mtime on a live database.
    my $db = DBI->connect( "dbi:SQLite:dbname=$dbname", q{}, q{}, { RaiseError => 1, PrintError => 0 } );

    if ($schema) {

        # No pre-flight test: read_text dies with "Cannot open <path>: <errno>",
        # which says more than the guard did and covers unreadable as well as absent.
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

Drop the cached handles.  Only tests should need this.

=cut

sub forget {
    $dbh = {};
    return 1;
}

1;
