#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/skills-teardown.t - the provisioning-recipes teardown: what a throwaway run leaves, and what it does not

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Path       qw{make_path};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/teardown")
  or BAIL_OUT('the teardown script does not load');

sub scratch_marker {
    my ($present) = @_;

    # The script is required at runtime, so this is the only mention of its
    # package variable that the compiler ever sees.
    no warnings 'once';    ## no critic (ProhibitNoWarnings)
    my $marker = $ENV{TROG_PROVISIONER_CONFIG} . '/' . $Trog::Skill::Teardown::MARKER;
    return unlink $marker unless $present;
    File::Slurper::Temp::write_text( $marker, "Built by scratch_config; safe to remove.\n" );
    return;
}

# Both streams, because half of what this script has to say about refusing to do
# something is said on stderr.
sub says {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open( my $o, '>', \$out ) or die "capture: $!";
    open( my $e, '>', \$err ) or die "capture: $!";
    my @returned;
    {
        local *STDOUT = $o;
        local *STDERR = $e;
        @returned = $code->();
    }
    close $o;
    close $e;
    return ( "$out$err", @returned );
}

# One run of main, with bin/destroy and the configuration's removal stood in for:
# what it would have asked bin/destroy for, and what it said.
sub teardown {
    my (@args) = @_;

    my @asked;
    my $script = Test::MockModule->new( 'Trog::Skill::Teardown', no_auto => 1 );
    $script->redefine( destroy_guest => sub { push @asked, [@_]; return 0 } );
    $script->redefine( remove_config => sub { return 0 } );

    my ($said) = says( sub { Trog::Skill::Teardown::main(@args) } );
    return ( $said, @asked );
}

subtest 'the data directory goes with a throwaway guest, and only with one' => sub {
    scratch_marker(1);
    my ( undef, $asked ) = teardown('vm.test');
    ok( $asked->[4], 'a scratch configuration asks bin/destroy for --purge-data' );

    ( undef, $asked ) = teardown( '--keep-data', 'vm.test' );
    ok( !$asked->[4], 'unless --keep-data says to leave it' );

    scratch_marker(0);
    my $said;
    ( $said, $asked ) = teardown('vm.test');
    ok( !$asked->[4], 'and a real configuration never does' );
    like( $said, qr/not a scratch configuration/, 'saying why' );
};

subtest 'what bin/destroy is asked for' => sub {
    my @ran;
    my $run3 = Test::MockModule->new('IPC::Run3');
    $run3->redefine( run3 => sub { push @ran, $_[0]; $? = 0; return 1 } );

    says( sub { Trog::Skill::Teardown::destroy_guest( 'vm.test', 'qemu:///system', undef, 1, 1 ) } );
    my @cmd = @{ $ran[0] }[ 2 .. $#{ $ran[0] } ];
    is_deeply( \@cmd, [qw{--purge --purge-data --connect qemu:///system --dryrun vm.test}], 'the domain directory, the data directory, and what was passed through' );

    @ran = ();
    says( sub { Trog::Skill::Teardown::destroy_guest( 'vm.test', undef, undef, 0, 0 ) } );
    is_deeply( [ @{ $ran[0] }[ 2 .. $#{ $ran[0] } ] ], [qw{--purge vm.test}], 'and no --purge-data when it was not decided on' );
};

subtest 'tearing one guest down keeps the configuration the others are built from' => sub {
    my $scratch = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $scratch;
    make_path("$scratch/recipes.d");
    File::Slurper::Temp::write_text( "$scratch/recipes.d/$_.yaml", "$_:\n    ntp:\n" ) for qw{cache.test consumer.test};

    # Not a scratch configuration: nothing in it is touched, whatever it holds.
    my ( $said, $rc ) = says( sub { Trog::Skill::Teardown::remove_config( 'cache.test', 0 ) } );
    is( $rc, 1, 'refused without the marker' );
    ok( -e "$scratch/recipes.d/cache.test.yaml", 'and nothing removed' );

    scratch_marker(1);
    ( $said, $rc ) = says( sub { Trog::Skill::Teardown::remove_config( 'cache.test', 1 ) } );
    like( $said, qr/Would remove .*cache\.test\.yaml.*consumer\.test/, 'a dry run says what it would keep, and for whom' );
    ok( -e "$scratch/recipes.d/cache.test.yaml", 'and keeps it' );

    ( $said, $rc ) = says( sub { Trog::Skill::Teardown::remove_config( 'cache.test', 0 ) } );
    ok( !-e "$scratch/recipes.d/cache.test.yaml",   'the domain torn down leaves the configuration' );
    ok( -e "$scratch/recipes.d/consumer.test.yaml", 'the other stays in it' );
    like( $said, qr/still configures consumer\.test/, 'and says why the rest is kept' );

    ( $said, $rc ) = says( sub { Trog::Skill::Teardown::remove_config( 'consumer.test', 0 ) } );
    is( $rc, 0, 'the last one out' );
    ok( !-e $scratch, 'takes the configuration with it' );
};

subtest 'the POD documents the interface' => sub {
    my $text = File::Slurper::read_text("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/teardown");

    like( $text, qr/=item B<--keep-data>/,  'POD documents --keep-data' );
    like( $text, qr{bin/destroy --orphans}, 'and points at the sweep, which is bin/destroy' );
};

done_testing();
