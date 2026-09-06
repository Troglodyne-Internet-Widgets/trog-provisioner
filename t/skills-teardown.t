#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/skills-teardown.t - the provisioning-recipes teardown: what a throwaway run leaves, and what it does not

=cut

use Test::More;
use File::Path qw{make_path};
use File::Temp qw{tempdir};
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

require_ok("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/teardown")
  or BAIL_OUT('the teardown script does not load');

# The data source these tests act on.  No hypervisors.conf is written into the
# configuration directory, so the fleet is empty and everything below is about
# the copy here -- which is the half that can be asserted on without one.
my $data = tempdir( CLEANUP => 1 );

sub write_config {
    my (%domains) = @_;

    my $dir  = $ENV{TROG_PROVISIONER_CONFIG};
    my $yaml = "_base:\n    data:\n        from: $data\n        to: /opt/domains\n";
    $yaml .= "$_:\n    ntp:\n" for sort keys %domains;

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", $yaml );
    Provisioner::Cookbook->forget();
    return;
}

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

subtest 'data_dir is the domain under the data source, but only for a scratch run' => sub {
    write_config( 'vm.test' => 1 );

    scratch_marker(0);
    my ( $said, @answer ) = says( sub { Trog::Skill::Teardown::data_dir('vm.test') } );
    is_deeply( \@answer, [], 'a real configuration gets no data directory to remove' );
    like( $said, qr/not a scratch configuration/, 'and says why' );

    scratch_marker(1);
    ( $said, @answer ) = says( sub { Trog::Skill::Teardown::data_dir('vm.test') } );
    is( $answer[0], "$data/vm.test", 'a scratch one gets the directory' );

    # With no fleet configured the hypervisor is this machine, and there is no
    # second copy to go and remove -- which is what purge_data_dir reads it for.
    ok( $answer[1]->is_local, 'and a hypervisor that is us, there being no fleet' );
};

subtest 'a domain that arrives with a path in it does not get to name the target' => sub {
    write_config();
    scratch_marker(1);

    my ( undef, @answer ) = says( sub { Trog::Skill::Teardown::data_dir('../../etc') } );
    is( $answer[0], "$data/....etc", 'the slashes come out before it is used' );

    ( undef, @answer ) = says( sub { Trog::Skill::Teardown::data_dir('..') } );
    is_deeply( \@answer, [], 'and a name that is only dots is refused outright' );
};

subtest 'purge_data_dir removes the directory, and dryrun does not' => sub {
    make_path("$data/gone.test");
    make_path("$data/kept.test");

    says( sub { Trog::Skill::Teardown::purge_data_dir( "$data/kept.test", undef, 1 ) } );
    ok( -d "$data/kept.test", 'a dry run leaves it where it is' );

    says( sub { Trog::Skill::Teardown::purge_data_dir( "$data/gone.test", undef, 0 ) } );
    ok( !-e "$data/gone.test", 'and a real one takes it' );

    # It is called on a domain whose provision died before it made one.
    my ($said) = says( sub { Trog::Skill::Teardown::purge_data_dir( "$data/never-was.test", undef, 0 ) } );
    like( $said, qr/never-was\.test/, 'a directory that was never there is not an error' );
};

subtest 'the sweep takes what belongs to no guest, and nothing else' => sub {
    write_config( 'named.test' => 1 );
    make_path("$data/$_") for qw{orphan.test named.test real.example.com};

    my ($said) = says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 1 ) } );
    like( $said, qr/orphan\.test/, 'the dry run names the orphan' );
    unlike( $said, qr/named\.test/, 'and not the one the configuration carries' );
    ok( -d "$data/orphan.test", 'and removes nothing' );

    says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 0 ) } );
    ok( !-e "$data/orphan.test", 'the sweep takes the orphan' );
    ok( -d "$data/named.test",   'leaves the one a recipe configuration names' );

    # Every real domain's data lives in the same directory, and the whole reason
    # this is safe to run is that it is only ever looking at .test.
    ok( -d "$data/real.example.com", 'and does not so much as consider a real domain' );
};

subtest 'a sweep with nothing to do says so' => sub {
    write_config( 'named.test' => 1 );

    my ( $said, $rc ) = says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 0 ) } );
    like( $said, qr/belongs to a guest that is gone/, 'says there is nothing' );
    is( $rc, 0, 'and is not a failure' );
};

subtest 'the POD documents the interface' => sub {
    my $text = File::Slurper::read_text("$FindBin::Bin/../.claude/skills/provisioning-recipes/scripts/teardown");

    like( $text, qr/=item B<--keep-data>/, 'POD documents --keep-data' );
    like( $text, qr/=item B<--orphans>/,   'POD documents --orphans' );
};

done_testing();
