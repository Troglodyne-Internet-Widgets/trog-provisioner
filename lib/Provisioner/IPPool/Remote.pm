package Provisioner::IPPool::Remote;

#ABSTRACT: Run bin/ippool on the hypervisor that keeps an address database.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Cwd();
use Cpanel::JSON::XS();
use Digest::SHA();
use File::Basename();
use Sys::Hostname();

use Provisioner::IPPool::DB();

# Trog::SQLite loads Sub::Retry, which the kit takes from %INC too.
use Trog::SQLite();

=head1 NAME

Provisioner::IPPool::Remote - run bin/ippool on the hypervisor that keeps an address database

=head1 SYNOPSIS

    use Provisioner::IPPool::Remote();

    # $hv is a remote Trog::HV::Libvirt whose block names ip_db.
    my $taken = Provisioner::IPPool::Remote::call( $hv, '/bogus/ips.db', 'taken', {} );

=head1 DESCRIPTION

Each hypervisor keeps its own F<ips.db>, and only processes on that hypervisor
open it.  L<Provisioner::IPPool::DB> says why.  A caller on another machine
runs one operation there, and this module is how.

=head2 The kit

The far side runs a copy of F<bin/ippool>, with what it loads, from the
checkout of the caller: the kit.  Its files are in C<kit_files>.  Before an
operation, this module asks the hypervisor for the hash of the kit that it has,
and puts the kit there when that hash is not the hash of the kit of the caller.
The copy is in a directory named by its hash, under C<$KIT_BASE> in the home
of the login user.  So two runners on two checkouts each run their own copy,
and neither overwrites the copy that the other one runs.  A copy goes into a
directory of its own first, and is renamed into place only when it is
complete, so an operation never runs half a kit.  Old copies stay until
somebody removes them; each is about sixty kilobytes.

=head2 What the far side needs

The system perl of the hypervisor, 5.36 or later, with L<DBI>,
L<DBD::SQLite>, L<File::Slurper> and L<JSON::PP>.  On Debian and Ubuntu:

    sudo apt install libdbd-sqlite3-perl libfile-slurper-perl

L<Trog::SQLite> and L<Sub::Retry> come in the kit.  The C<ip_perl> of the block
of the hypervisor names another perl, such as one that
F<scripts/build_latest_perl.sh> built there, with DBD::SQLite.  The C<check> operation of F<bin/ippool>
says what runs there.

=head2 The operation

The arguments go on the standard input of F<bin/ippool>, as JSON, because an
argument cannot be longer than 128 KiB.  It prints one JSON object, with the
result in C<result> or the error in C<error>.

=head1 SUBROUTINES

=head2 $KIT_BASE

Where the copies of the kit go on a hypervisor, relative to the home of the
login user: F<.cache/trog-provisioner/ippool>.

=cut

our $KIT_BASE = '.cache/trog-provisioner/ippool';

# The directory of the kit that each machine has, by what describes the
# machine and the hash, and the machine whose connection is open.
my ( %READY, %MACHINE );

=head2 forget()

Forgets which machine has which kit, and the connections that this module
keeps, so that the next call asks again.  The tests use it.

Takes no arguments.

Returns Int, 1.

    Provisioner::IPPool::Remote::forget();

=cut

sub forget {
    %READY   = ();
    %MACHINE = ();
    return 1;
}

=head2 %files = kit_files()

Each file of the kit, at its path in the kit, to the file of this machine that
it is a copy of: F<bin/ippool>, L<Provisioner::IPPool::DB>, F<schema/ips.sql>
and its updates, and L<Trog::SQLite> and L<Sub::Retry> as this process loaded
them.

Takes no arguments.

Returns a list of pairs of Str, from each path in the kit to the file on this
machine.

    my %files = Provisioner::IPPool::Remote::kit_files();

=cut

sub kit_files {
    my $root   = Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../..' );
    my $schema = Provisioner::IPPool::DB::schema_path();
    return (
        'bin/ippool'                   => "$root/bin/ippool",
        'lib/Provisioner/IPPool/DB.pm' => $INC{'Provisioner/IPPool/DB.pm'},
        'lib/Trog/SQLite.pm'           => $INC{'Trog/SQLite.pm'},
        'lib/Sub/Retry.pm'             => $INC{'Sub/Retry.pm'},
        'schema/ips.sql'               => $schema,
        map { local ($_) = $_; ( 'schema/' . File::Basename::basename( $_->[1] ) => $_->[1] ) } Trog::SQLite::updates($schema),
    );
}

=head2 $hash = kit_hash(%files)

The SHA-256 of the kit C<%files>, as C<kit_files> gives it: of each path in
the kit, and the content of its file, in the order of the paths.

=over 4

=item files - HASH - the kit, as C<kit_files> returns it

=back

Returns Str, the hash, in hex.

    my $hash = Provisioner::IPPool::Remote::kit_hash( Provisioner::IPPool::Remote::kit_files() );

=cut

sub kit_hash (%files) {
    my $sha = Digest::SHA->new(256);
    foreach my $path ( sort keys %files ) {
        $sha->add("$path\0");
        $sha->addfile( $files{$path} );
        $sha->add("\0");
    }
    return $sha->hexdigest;
}

# What the copy of the kit in $dir on $machine says its hash is, or nothing.
my sub hash_there ( $machine, $dir ) {
    my $said = $machine->capture_cmd( 'sh', '-c', 'cat "$1/.complete" 2>/dev/null', 'sh', $dir ) // q{};
    chomp $said;
    return $said;
}

=head2 $dir = ensure_kit($machine)

The directory of the kit of this checkout on C<$machine>, a L<Trog::Machine>,
which this puts there when the hypervisor does not have it.  Asks once in each
process for each machine.  Dies when the copy cannot be made.

=over 4

=item machine - Trog::Machine - the hypervisor

=back

Returns Str, the directory, relative to the home of the login user.

    my $dir = Provisioner::IPPool::Remote::ensure_kit($hv);

=cut

sub ensure_kit ($machine) {
    my %files = kit_files();
    my $hash  = kit_hash(%files);
    my $dir   = "$KIT_BASE/$hash";
    my $key   = $machine->describe . "\0$hash";
    return $READY{$key} if $READY{$key};

    if ( hash_there( $machine, $dir ) ne $hash ) {

        # A directory of its own for each copy, so that two runners that put the
        # same kit at once do not write into one directory.
        my $stage = "$dir.part." . Sys::Hostname::hostname() . ".$$";
        my %dirs  = map { local ($_) = $_; ( "$stage/" . File::Basename::dirname($_) => 1 ) } keys %files;
        $machine->mkpath( sort keys %dirs ) or die 'Could not make ' . $stage . ' on ' . $machine->describe . " for the kit of bin/ippool\n";
        foreach my $path ( sort keys %files ) {
            $machine->put_file( $files{$path}, "$stage/$path" ) or die "Could not put $path of the kit of bin/ippool on " . $machine->describe . "\n";
        }
        $machine->write_text( "$stage/.complete", "$hash\n" ) or die 'Could not finish the kit of bin/ippool on ' . $machine->describe . "\n";

        # mv -T fails when the other runner was first, and then its copy, which
        # is the same, stays.
        $machine->capture_cmd( 'sh', '-c', 'mv -T "$1" "$2" 2>/dev/null || rm -rf "$1"', 'sh', $stage, $dir );
        my $now = hash_there( $machine, $dir );
        die 'The kit of bin/ippool on ' . $machine->describe . " is at $dir, but says it is '$now' and not $hash.  Remove $dir there, and try again.\n"
          unless $now eq $hash;
    }

    return $READY{$key} = $dir;
}

=head2 $result = call($machine, $path, $op, $args, %opts)

Runs the operation C<$op> of L<Provisioner::IPPool::DB> with C<$args> on the
database at C<$path> on C<$machine>, a remote L<Trog::HV>, through the kit,
and returns its result.  C<create> in C<%opts> lets it make the database.  The
perl is the C<ip_perl> of the hypervisor.

Dies with the error of the operation when it fails there.  Dies naming the
hypervisor when it cannot be reached, or does not answer with JSON, with what
it printed on standard error.

=over 4

=item machine - Trog::HV - the hypervisor that keeps the database

=item path - Str - the path of the database there

=item op - Str - the name of the operation

=item args - HashRef - optional: the arguments of the operation, empty by default

=item create - Bool - optional: make the database when it does not exist

=back

Returns Any, the result of the operation.

    my $taken = Provisioner::IPPool::Remote::call( $hv, '/bogus/ips.db', 'taken', {} );

=cut

sub call ( $machine, $path, $op, $args = {}, %opts ) {
    $machine = $MACHINE{ $machine->describe } //= $machine;
    my $where = $machine->name // $machine->describe;

    my ( $out, $err );
    my $ok = eval {
        my $dir = ensure_kit($machine);
        ( $out, $err ) = $machine->capture_with_input(
            Cpanel::JSON::XS->new->canonical->encode( $args // {} ),
            $machine->ip_perl, "-I$dir/lib", "$dir/bin/ippool", '--db', $path, ( $opts{create} ? '--create' : () ), $op
        );
        1;
    };
    die "Could not ask $where for the addresses that it keeps: $@" unless $ok;

    my $answer = eval { Cpanel::JSON::XS->new->allow_nonref->decode( $out // q{} ) };
    die "$where did not answer the $op of bin/ippool" . ( ( $err // q{} ) ne q{} ? ":\n$err" : ".\n" ) unless ref $answer eq 'HASH';
    die $answer->{error} if defined $answer->{error};
    return $answer->{result};
}

1;
