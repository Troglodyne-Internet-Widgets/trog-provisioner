#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/new_config-salvage.t - refresh_salvage: a failed refresh that changed nothing, and one that did

=cut

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";
require Trog::Guest;

# One fake guest: run_sudo says whether the command failed, and capture answers
# the mtime probe with whatever this test wants the tree to look like at that
# moment.  It keeps what it was constructed with, because refresh_salvage names
# the host in every message it prints and asks the guest which host that is.
sub guest_that {
    my (%behaviour) = @_;

    my @probes = @{ $behaviour{mtimes} };
    my $mock   = Test::MockModule->new('Trog::Guest');
    $mock->redefine( new      => sub { my ( $class, %opts ) = @_; return bless {%opts}, $class } );
    $mock->redefine( run_sudo => sub { $behaviour{exit} } );
    $mock->redefine(
        capture => sub {
            my $now = shift @probes // $probes[-1];
            return join q{}, map { "$_\t$now->{$_}\n" } sort keys %$now;
        }
    );

    return $mock;
}

sub refresh {
    my (@args) = @_;
    return Trog::Provisioner::Config::Generator::refresh_salvage( qw{192.168.1.9 admin /nonexistent mariadb}, @args );
}

# Both halves of a salvage want the guest -- refresh_salvage once a module, the
# fetch once for each thing that module salvages -- and each of those used to be
# its own ssh handshake against a machine that is about to be thrown away.
subtest 'one connection per guest, however many times a run asks for one' => sub {
    my $built = 0;
    my $mock  = Test::MockModule->new('Trog::Guest');
    $mock->redefine(
        new => sub {
            my ( $class, %opts ) = @_;
            $built++;
            return bless {%opts}, $class;
        }
    );

    my $first = Trog::Provisioner::Config::Generator::_salvage_guest(qw{10.0.0.1/24 admin /nonexistent});
    my $again = Trog::Provisioner::Config::Generator::_salvage_guest(qw{10.0.0.1/24 admin /nonexistent});

    is( $built,       1,          'asking twice opens one connection' );
    is( $again,       $first,     'and the second ask gets the one already open' );
    is( $first->name, '10.0.0.1', 'the address it connects to is not the cidr it was given' );

    # A run configures several domains, and each of them is a different guest.
    my $other = Trog::Provisioner::Config::Generator::_salvage_guest(qw{10.0.0.2/24 admin /nonexistent});
    is( $built, 2, 'a different guest is a different connection' );
    isnt( $other, $first, 'rather than the last one answered for it' );
};

subtest 'a refresh that worked says nothing' => sub {
    my $guard = guest_that( exit => 0, mtimes => [ { '/var/backups/db' => '100' }, { '/var/backups/db' => '200' } ] );

    my @said;
    local $SIG{__WARN__} = sub { push @said, @_ };
    is( refresh( ['dump-it'], ['/var/backups/db'] ), 1, 'it ran' );
    is_deeply( \@said, [], 'and warned about nothing' );
};

subtest 'a refresh that failed having touched nothing is a warning' => sub {
    my $guard = guest_that( exit => 1, mtimes => [ { '/var/backups/db' => '100' }, { '/var/backups/db' => '100' } ] );

    # Last night's dump is still exactly last night's dump.  Worth having, and
    # worth saying it is old.
    my @said;
    local $SIG{__WARN__} = sub { push @said, @_ };
    my $err = exception { refresh( ['dump-it'], ['/var/backups/db'] ) };
    is( $err, undef, 'it does not die' );
    like( join( q{}, @said ), qr/as old as the last time/, 'and says what came down is stale' );
};

subtest 'a refresh that failed having changed something dies before anything is fetched' => sub {
    my $guard = guest_that( exit => 1, mtimes => [ { '/var/backups/db' => '100' }, { '/var/backups/db' => '250' } ] );

    # This is the case the whole probe is for: a mysqldump killed midway leaves
    # a partial file, not a stale one, and fetching it would carry a corrupt
    # copy home and call it the state of the guest.
    my $err = exception { refresh( ['dump-it'], ['/var/backups/db'] ) };
    like( $err, qr/after changing what it was refreshing/, 'it dies' );
    like( $err, qr{/var/backups/db},                       'naming what it touched' );
};

subtest 'each command is judged against what the one before it left' => sub {

    # The first command succeeds and moves the mtime, which is its job.  The
    # second fails without touching anything.  Comparing the second against the
    # state before the first would blame it for the first's work.
    my @probes = ( { '/var/backups/db' => '100' }, { '/var/backups/db' => '200' }, { '/var/backups/db' => '200' } );
    my @exits  = ( 0, 1 );

    my $mock = Test::MockModule->new('Trog::Guest');
    $mock->redefine( new      => sub { my ( $class, %opts ) = @_; return bless {%opts}, $class } );
    $mock->redefine( run_sudo => sub { shift @exits } );
    $mock->redefine(
        capture => sub {
            my $now = shift @probes;
            return join q{}, map { "$_\t$now->{$_}\n" } sort keys %$now;
        }
    );

    my @said;
    local $SIG{__WARN__} = sub { push @said, @_ };
    my $err = exception { refresh( [ 'snapshot', 'dump-it' ], ['/var/backups/db'] ) };
    is( $err, undef, 'the second failure is not blamed for the first success' );
    like( join( q{}, @said ), qr/as old as the last time/, 'and is reported as a stale refresh' );
};

subtest 'a recipe that watches nothing is not probed at all' => sub {
    my $asked = 0;
    my $mock  = Test::MockModule->new('Trog::Guest');
    $mock->redefine( new      => sub { my ( $class, %opts ) = @_; return bless {%opts}, $class } );
    $mock->redefine( run_sudo => sub { 0 } );
    $mock->redefine( capture  => sub { $asked++; return q{} } );

    is( refresh( ['dump-it'], [] ), 1, 'it still runs the command' );
    is( $asked,                     0, 'and asks the guest for no mtimes' );
};

done_testing();
