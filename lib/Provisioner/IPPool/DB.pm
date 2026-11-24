package Provisioner::IPPool::DB;

#ABSTRACT: The address database of one hypervisor, which only processes on that hypervisor open.

# 5.036 and not 5.041: this module runs on the system perl of a hypervisor, as
# a part of the kit that Provisioner::IPPool::Remote puts there.
use 5.036;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

use Cwd();
use File::Basename();
use List::Util qw{all first};

use Trog::SQLite();

=head1 NAME

Provisioner::IPPool::DB - the address database of one hypervisor

=head1 SYNOPSIS

    use Provisioner::IPPool::DB();

    # What bin/ippool does on the hypervisor that keeps the database.
    my $ip = Provisioner::IPPool::DB::run( '/bogus/ips.db', 'assign', {
        domain     => 'test.test',
        bin        => 'guests',
        nic        => 'br0',
        main       => 1,
        guest      => 1,
        candidates => [qw{192.0.2.10 192.0.2.11}],
    } );

=head1 DESCRIPTION

This is the part of L<Provisioner::IPPool> that reads and writes F<ips.db>.
It knows nothing about the configuration, the fleet or a guest.  The caller
works out which addresses a bin holds, and this module chooses among them and
records the choice.

SQLite in WAL mode coordinates two writers through a file that each of them maps
into memory.  That works only when both are on one machine.  Two machines that
share the file over a network filesystem, such as two runners that mount the
configuration directory of their hypervisor, can each see a different state of
it, and corrupt an index.  So each hypervisor keeps
its own database, and only processes on that hypervisor open it.  A caller on
another machine runs F<bin/ippool> there, over ssh, see
L<Provisioner::IPPool::Remote>.

So everything that one operation reads and writes happens here, in one
process, and C<assign> reads what is taken and inserts in one transaction.

The module needs only what a hypervisor has, or can get from its packages: perl
5.36, L<DBI>, L<DBD::SQLite> and L<File::Slurper>.  L<Trog::SQLite> and
L<Sub::Retry> come in the kit.

=head1 OPERATIONS

C<run> takes the name of one of these, and a hash reference of its arguments.
Each one is also a sub of this module, which takes the handle and that hash
reference.  What each returns is plain data, which F<bin/ippool> prints as
JSON.

=cut

our $GUESTS = 'guests';

=head2 schema_path()

The absolute path of F<schema/ips.sql>, found from the location of this file.
The kit keeps the same layout as the checkout, so the path works in both.

=cut

sub schema_path {
    return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../../schema/ips.sql' );
}

=head2 dbh($path, %opts)

The handle on the database at C<$path>, with its schema and updates applied, as
L<Trog::SQLite/dbh> gives it, which checks the integrity of the database the
first time a process opens it.

Dies when there is no file at C<$path>, unless C<create> is true.  A database
that a typo in C<ip_db> made would be empty, and an empty database gives out
addresses that guests already use.  So only C<init>, and the database of a
machine with no fleet, make one.

F<schema/ips.v1.update.sql> adds bins, and puts every row of a database from
before them in the C<guests> bin.  F<schema/ips.v2.update.sql> adds the bridge
of each address, and marks the address of each guest.  A row from before it
has no bridge, and is the address of its guest.  C<assign> gives it the bridge
whose pool holds it, the first time that its domain asks for an address on
that bridge, so a guest keeps its address.

F<schema/ips.v3.update.sql> puts the rows in the table C<addresses>, with the
kind, the bin and the bridge of each as the id of a name in C<address_kinds>,
C<address_bins> and C<address_nics>, and makes C<ips> a view with the columns
that it had, which takes writes too.  C<noted> is C<assigned_at> there.  A kind
other than C<domain> and C<reserved> is refused.  A write through the view
reports no rows, so where the number matters, count the rows of C<addresses>
with C<do_with_update_hook> of L<Trog::SQLite>.

=cut

sub dbh ( $path, %opts ) {
    die "There is no address database at $path.  Make it with the init of bin/ippool, then fill it with its migrate, or with bin/reseed_ips.\n"
      unless $opts{create} || -e $path;
    return Trog::SQLite::dbh( schema_path(), $path, { integrity_check => 1 } );
}

# The number of rows of addresses that $sql, a write to the view ips with
# @bind, writes, which do cannot count.
my sub rows_written ( $db, $sql, @bind ) {
    my $rows = 0;
    Trog::SQLite::do_with_update_hook( $db, sub ( $action, $database, $table, $rowid ) { $rows++ if $table eq 'addresses' }, $sql, @bind );
    return $rows;
}

=head2 check

What runs this: the version of perl and of SQLite, the path of the database,
and where L<Trog::SQLite> was loaded from.  F<bin/ippool> answers it without a
database, so that a caller can see whether a hypervisor can run the kit at all.

=cut

sub check ( $db, @ ) {
    return {
        perl          => sprintf( '%vd', $^V ),
        sqlite        => $DBD::SQLite::sqlite_version,
        sqlite_module => $INC{'Trog/SQLite.pm'},
        ( $db ? ( path => $db->sqlite_db_filename() ) : () ),
    };
}

=head2 init

Makes the database, if it is not there, and returns its path.

=cut

sub init ( $db, @ ) {
    return $db->sqlite_db_filename();
}

=head2 assignments

Each guest domain, to the address of the guest: its main address in the
C<guests> bin.

=cut

sub assignments ( $db, @ ) {
    my $rows = $db->selectall_arrayref( "SELECT domain, ip FROM ips WHERE kind = 'domain' AND bin = ? AND main = 1", { Slice => {} }, $GUESTS );
    return { map { $_->{domain} => $_->{ip} } @$rows };
}

=head2 taken

Each address, to the name that holds it, reservations too.

=cut

sub taken ( $db, @ ) {
    my $rows = $db->selectall_arrayref( 'SELECT ip, domain FROM ips', { Slice => {} } );
    return { map { $_->{ip} => $_->{domain} } @$rows };
}

=head2 bridges

Each address of a guest in the C<guests> bin, to its bridge.

=cut

sub bridges ( $db, @ ) {
    my $rows = $db->selectall_arrayref( "SELECT ip, nic FROM ips WHERE kind = 'domain' AND bin = ?", { Slice => {} }, $GUESTS );
    return { map { $_->{ip} => $_->{nic} } @$rows };
}

=head2 held_by

The address that C<domain> has in C<bin>, on C<nic> when it is given, or else its
main one, or undef.  Domains only, never a reservation.

=cut

sub held_by ( $db, $args ) {
    my ( $domain, $bin, $nic ) = @{$args}{qw{domain bin nic}};
    my $row =
      defined $nic
      ? $db->selectrow_arrayref( "SELECT ip FROM ips WHERE domain = ? AND kind = 'domain' AND bin = ? AND nic = ?", undef, $domain, $bin // $GUESTS, $nic )
      : $db->selectrow_arrayref( "SELECT ip FROM ips WHERE domain = ? AND kind = 'domain' AND bin = ? AND main = 1", undef, $domain, $bin // $GUESTS );
    return $row ? $row->[0] : undef;
}

=head2 main_addresses

Each bin in which C<domain> has an address, to its main address there.

=cut

sub main_addresses ( $db, $args ) {
    my $rows = $db->selectall_arrayref( "SELECT bin, ip FROM ips WHERE domain = ? AND kind = 'domain' AND main = 1", { Slice => {} }, $args->{domain} );
    return { map { $_->{bin} => $_->{ip} } @$rows };
}

=head2 nic_addresses

Each bridge on which C<domain> has an address in the C<guests> bin, to that
address.

=cut

sub nic_addresses ( $db, $args ) {
    my $rows = $db->selectall_arrayref( "SELECT nic, ip FROM ips WHERE domain = ? AND kind = 'domain' AND bin = ? AND nic != ''", { Slice => {} }, $args->{domain}, $GUESTS );
    return { map { $_->{nic} => $_->{ip} } @$rows };
}

=head2 reserve

Records C<ip> as held by C<name>, which no guest gets, on the bridge C<nic>.
Returns 1 when this wrote the row, and 0 when the address was already there.

=cut

sub reserve ( $db, $args ) {
    return rows_written( $db, "INSERT OR IGNORE INTO ips (ip, domain, kind, nic) VALUES (?, ?, 'reserved', ?)", @{$args}{qw(ip name)}, $args->{nic} // q{} ) ? 1 : 0;
}

=head2 record

Records C<ip> as the address of the guest C<domain> on the bridge C<nic>, the
main one unless C<main> is false.  A row of C<domain> for C<ip> from before
bridges gets C<nic> instead.  Returns 1 when this wrote a row.

=cut

sub record ( $db, $args ) {
    my ( $ip, $domain ) = @{$args}{qw{ip domain}};
    my $nic = $args->{nic} // q{};
    return 1
      if $nic ne q{}
      && rows_written( $db, "UPDATE OR IGNORE ips SET nic = ? WHERE ip = ? AND domain = ? AND kind = 'domain' AND bin = ? AND nic = ''", $nic, $ip, $domain, $GUESTS );
    return rows_written( $db, "INSERT OR IGNORE INTO ips (ip, domain, kind, nic, main) VALUES (?, ?, 'domain', ?, ?)", $ip, $domain, $nic, ( $args->{main} // 1 ) ? 1 : 0 ) ? 1 : 0;
}

=head2 release

Deletes every address of C<domain>, and returns what it gave back: each bin to
its main address, and C<guests on NIC> to each other address in C<guests>.

=cut

sub release ( $db, $args ) {
    my $domain = $args->{domain};
    my %held;
    Trog::SQLite::transaction(
        $db,
        sub {
            %held = %{ main_addresses( $db, $args ) };
            my $rows = $db->selectall_arrayref( "SELECT nic, ip FROM ips WHERE domain = ? AND kind = 'domain' AND bin = ? AND main = 0", { Slice => {} }, $domain, $GUESTS );
            $held{"$GUESTS on $_->{nic}"} = $_->{ip} foreach @$rows;
            $db->do( "DELETE FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );
        }
    );
    return \%held;
}

=head2 assign

The address of C<domain> in C<bin>, on the bridge C<nic>, out of C<candidates>,
the addresses of that bin in order.  C<guest> is true for the C<guests> bin,
and C<main> says whether C<nic> gives the address of the guest.  A domain that
has an address keeps it.  Otherwise it gets the first candidate that nothing
holds.  See L<Provisioner::IPPool/assign($domain, $pool, $bin, $nic)>.

All of it is one transaction, which takes the write lock before it reads: see
L<Trog::SQLite/transaction>, and C<sqlite_use_immediate_transaction> of
L<DBD::SQLite>.  So two of these at once on one hypervisor cannot give out one
address twice.

=cut

sub assign ( $db, $args ) {
    my ( $domain, $bin, $nic, $main, $guest ) = @{$args}{qw{domain bin nic main guest}};
    my @candidates = @{ $args->{candidates} // [] };
    my %in_bin     = map { $_ => 1 } @candidates;
    $nic //= q{};

    my $address;
    Trog::SQLite::transaction(
        $db,
        sub {
            my $held = held_by( $db, { domain => $domain, bin => $bin, nic => $nic } );

            # An address from before the database recorded bridges, in the pool of
            # this one, is the address that the guest has on it.
            my $old = !defined $held && $nic ne q{} ? held_by( $db, { domain => $domain, bin => $bin, nic => q{} } ) : undef;
            if ( defined $old && $in_bin{$old} ) {
                $db->do( "UPDATE ips SET nic = ? WHERE domain = ? AND kind = 'domain' AND bin = ? AND nic = ''", undef, $nic, $domain, $bin );
                $held = $old;
            }

            if ($held) {
                if ($guest) {
                    $db->do( "UPDATE ips SET main = CASE WHEN nic = ? THEN 1 ELSE 0 END WHERE domain = ? AND kind = 'domain' AND bin = ?", undef, $nic,    $domain, $bin ) if $main;
                    $db->do( "UPDATE ips SET main = 0 WHERE domain = ? AND kind = 'domain' AND bin = ? AND nic = ?",                       undef, $domain, $bin,    $nic ) unless $main;
                }
                $address = $held;
                return;
            }

            my $taken = taken( $db, {} );
            my $free  = first { !$taken->{$_} } @candidates;
            die "IP pool exhausted: no IPs available for $domain" . ( $nic ne q{} ? " on $nic" : q{} ) . "\n" unless $free;

            $db->do( "UPDATE ips SET main = 0 WHERE domain = ? AND kind = 'domain' AND bin = ?", undef, $domain, $bin ) if $guest && $main;
            $db->do( "INSERT INTO ips (ip, domain, kind, bin, nic, main) VALUES (?, ?, 'domain', ?, ?, ?)", undef, $free, $domain, $bin, $nic, $main ? 1 : 0 );
            $address = $free;
            return;
        }
    );
    return $address;
}

=head2 forget_seeding

Deletes the record of which hypervisors were seeded.  Returns how many.

=cut

sub forget_seeding ( $db, @ ) {
    my $rows = $db->do('DELETE FROM seeded');
    return $rows && $rows ne '0E0' ? $rows + 0 : 0;
}

=head2 clear_reservations

Deletes each reservation, and returns how many.  Assignments stay.

=cut

sub clear_reservations ( $db, @ ) {
    return rows_written( $db, "DELETE FROM ips WHERE kind = 'reserved'" );
}

=head2 seeded

The sources that a seed finished, such as C<hv:hv1>.

=cut

sub seeded ( $db, @ ) {
    return $db->selectcol_arrayref('SELECT source FROM seeded ORDER BY source');
}

# Applies one seed, as the seed operation takes it, in the transaction of the
# caller, and returns the number of rows that it wrote.
my sub apply_seed ( $db, $seed ) {
    my $written = 0;
    foreach my $row ( @{ $seed->{rows} // [] } ) {
        my ( $what, @values ) = @$row;
        $written += reserve( $db, { ip => $values[0], name => $values[1], nic => $values[2] } )                      if $what eq 'reserve';
        $written += record( $db, { ip => $values[0], domain => $values[1], nic => $values[2], main => $values[3] } ) if $what eq 'record';
        die "A seed has no rows of the kind '$what', only reserve and record\n" unless $what eq 'reserve' || $what eq 'record';
    }
    for my $item ( @{ $seed->{mark} // [] } ) { $db->do( 'INSERT OR IGNORE INTO seeded (source) VALUES (?)', undef, $item ); }
    return $written;
}

=head2 seed

Writes C<rows> in their order, each C<[reserve, IP, NAME, NIC]> or
C<[record, IP, DOMAIN, NIC, MAIN]>, as C<reserve> and C<record> do, and then
marks each source of C<mark> as seeded, in one transaction.  Returns the
number of rows written.  The caller asked the hypervisor what is in use, so a
seed that could not finish writes nothing and marks nothing.

=cut

sub seed ( $db, $args ) {
    my $written = 0;
    Trog::SQLite::transaction( $db, sub { $written = apply_seed( $db, $args ) } );
    return $written;
}

=head2 reseed

In one transaction: forgets which hypervisors were seeded, deletes every
reservation, writes each seed of C<seeds> as C<seed> does, and with C<prune>,
a list of the guests that run, releases each domain that holds an address
here and is not in it.  Reservations of C<hv:>, C<gateway:> and C<insitu:> are
not domains.  With C<dryrun>, it rolls all of that back.

Returns C<before> and C<after>, what C<taken> says, C<on> and C<on_after>,
what C<bridges> says, and C<pruned>, how many domains it released.

=cut

sub reseed ( $db, $args ) {
    my %out;
    $db->do('BEGIN IMMEDIATE');
    my $ok = eval {
        $out{before} = taken( $db, {} );
        $out{on}     = bridges( $db, {} );
        forget_seeding( $db, {} );
        clear_reservations( $db, {} );
        for my $seed ( @{ $args->{seeds} // [] } ) { apply_seed( $db, $seed ); }

        $out{pruned} = 0;
        if ( $args->{prune} ) {
            my %running = map { $_ => 1 } @{ $args->{prune} };
            my %domains = map { $_ => 1 } grep { !m/\A(?:hv|gateway|insitu):/ && !$running{$_} } values %{ $out{before} };
            foreach my $domain ( sort keys %domains ) {
                $db->do( "DELETE FROM ips WHERE domain = ? AND kind = 'domain'", undef, $domain );
                $out{pruned}++;
            }
        }

        $out{after}    = taken( $db, {} );
        $out{on_after} = bridges( $db, {} );
        $db->do( $args->{dryrun} ? 'ROLLBACK' : 'COMMIT' );
        1;
    };
    unless ($ok) {
        my $err = $@ || "The reseed failed\n";
        eval { $db->do('ROLLBACK') };    ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval) -- the failure worth reporting is $err, not a rollback of it that could not run
        die $err;
    }
    return \%out;
}

=head2 migrate

Writes C<rows>, each a hash of C<ip>, C<domain>, C<kind>, C<bin>, C<nic>,
C<main> and C<assigned_at> as the view C<ips> has them, and marks each source
of C<seeded>, in one transaction.  A row that is already here as it is is
skipped.  Dies, and writes nothing, when an address or a name of a row is
here with another holder or another address.  With C<dryrun>, it writes nothing.
Returns C<added> and C<kept>, the numbers of rows.

=cut

sub migrate ( $db, $args ) {
    my %out = ( added => 0, kept => 0 );
    my @conflicts;

    # A dry run ends in a die, which is how the transaction rolls back.
    my $ran = eval {
        Trog::SQLite::transaction(
            $db,
            sub {
                foreach my $row ( @{ $args->{rows} // [] } ) {
                    my $here = $db->selectrow_hashref( 'SELECT ip, domain, kind, bin, nic FROM ips WHERE ip = ?', undef, $row->{ip} );
                    if ($here) {
                        my $same = all { ( $here->{$_} // q{} ) eq ( $row->{$_} // q{} ) } qw{domain kind bin nic};
                        $same ? $out{kept}++ : push( @conflicts, "$row->{ip} is $here->{domain} ($here->{kind}, $here->{bin}) here, and $row->{domain} ($row->{kind}, $row->{bin}) in the old database" );
                        next;
                    }
                    $db->do( 'INSERT INTO ips (ip, domain, kind, bin, nic, main, assigned_at) VALUES (?, ?, ?, ?, ?, ?, coalesce(?, datetime(\'now\')))', undef, @{$row}{qw{ip domain kind bin nic main assigned_at}} );
                    $out{added}++;
                }
                for my $item ( @{ $args->{seeded} // [] } ) { $db->do( 'INSERT OR IGNORE INTO seeded (source) VALUES (?)', undef, $item ); }
                die "Nothing was migrated, because these addresses disagree:\n" . join( q{}, map { "  $_\n" } @conflicts ) if @conflicts;
                die "__DRYRUN__\n"                                                                                         if $args->{dryrun};
            }
        );
    };
    die $@ unless $ran || $@ eq "__DRYRUN__\n";
    return \%out;
}

=head2 run($path, $op, $args, %opts)

Opens the database at C<$path>, as C<dbh> does with C<%opts>, and returns what
the operation C<$op> returns for C<$args>.  C<check> runs without a database
when there is none.  Dies on an operation that is not one of the above.

=cut

my %OPS = (
    check              => \&check,
    init               => \&init,
    assignments        => \&assignments,
    taken              => \&taken,
    bridges            => \&bridges,
    held_by            => \&held_by,
    main_addresses     => \&main_addresses,
    nic_addresses      => \&nic_addresses,
    reserve            => \&reserve,
    record             => \&record,
    release            => \&release,
    assign             => \&assign,
    forget_seeding     => \&forget_seeding,
    clear_reservations => \&clear_reservations,
    seeded             => \&seeded,
    seed               => \&seed,
    reseed             => \&reseed,
    migrate            => \&migrate,
);

=head2 @ops = operations()

The names of the operations, sorted.

=cut

sub operations {
    my @ops = sort keys %OPS;
    return @ops;
}

sub run ( $path, $op, $args = {}, %opts ) {
    my $code = $OPS{ $op // q{} } or die "bin/ippool has no operation '" . ( $op // q{} ) . "'.  It has: " . join( ', ', operations() ) . "\n";
    return check( undef, $args ) if $op eq 'check' && !-e $path;

    my $db = dbh( $path, %opts, ( $op eq 'init' ? ( create => 1 ) : () ) );
    return $code->( $db, $args // {} );
}

1;
