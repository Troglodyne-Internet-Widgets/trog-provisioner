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

use Provisioner::Cookbook();
use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();    ## no critic (ProhibitUnusedImports)

# Enough of Sys::Virt to answer the one question the sweep asks of it.
{

    package Test::Libvirt;
    our @DOMAINS;

    sub list_all_domains {
        return map { bless { name => $_ }, 'Test::Libvirt::Domain' } @DOMAINS;
    }

    package Test::Libvirt::Domain;
    sub get_name { return $_[0]->{name} }
}

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

    # real.example is not .test on purpose, and must not be "corrected" to it:
    # it stands for a domain somebody actually runs, and the assertion at the
    # end of this subtest is that the sweep never looks at one.  Under .test it
    # would be an orphan by definition and the sweep would be right to take it.
    # (.example is reserved by RFC 2606 just as .test is, so it resolves
    # nowhere either.)
    make_path("$data/$_") for qw{orphan.test named.test real.example};

    my ($said) = says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 1 ) } );
    like( $said, qr/orphan\.test/, 'the dry run names the orphan' );
    unlike( $said, qr/named\.test/, 'and not the one the configuration carries' );
    ok( -d "$data/orphan.test", 'and removes nothing' );

    says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 0 ) } );
    ok( !-e "$data/orphan.test", 'the sweep takes the orphan' );
    ok( -d "$data/named.test",   'leaves the one a recipe configuration names' );

    # Every real domain's data lives in the same directory, and the whole reason
    # this is safe to run is that it is only ever looking at .test.
    ok( -d "$data/real.example", 'and does not so much as consider a real domain' );
};

subtest 'the sweep covers the domain directory as well as the data source' => sub {
    my $domains = tempdir( CLEANUP => 1 );
    write_config( 'named.test' => 1 );
    make_path("$data/$_")    for qw{orphan.test live.test};
    make_path("$domains/$_") for qw{orphan.test live.test named.test};

    # A hypervisor to have a domain directory and a list of guests.  Both of the
    # sweep's exclusions come from somewhere real: the configuration above, and
    # this.
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { $domains } );
    $hv->redefine( vmm        => sub { bless {}, 'Test::Libvirt' } );
    local @Test::Libvirt::DOMAINS = ('live.test');

    my ($said) = says( sub { Trog::Skill::Teardown::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    like( $said, qr/\Q$domains\E/, 'the domain directory is one of the places it looks' );

    ok( !-e "$data/orphan.test",    'the orphan goes from the data source' );
    ok( !-e "$domains/orphan.test", 'and from the domain directory' );

    ok( -d "$data/live.test",     'a guest libvirt still has is not an orphan' );
    ok( -d "$domains/live.test",  'in either place' );
    ok( -d "$domains/named.test", 'and neither is one the configuration names' );

    Trog::HV->forget();

    # It is only live while this subtest says it is.
    File::Path::remove_tree("$data/live.test");
};

subtest 'a hypervisor that will not say what it has stops the sweep' => sub {
    write_config();
    make_path("$data/orphan.test");

    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { tempdir( CLEANUP => 1 ) } );
    $hv->redefine( vmm        => sub { die "connection refused\n" } );

    my ( $said, $rc ) = says( sub { Trog::Skill::Teardown::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    is( $rc, 1, 'the sweep fails rather than carrying on' );
    like( $said, qr/nothing is swept/, 'and says so' );

    # The guests it holds are exactly the ones that would look like orphans.
    ok( -d "$data/orphan.test", 'nothing was removed on the strength of a list it could not get' );

    Trog::HV->forget();
    rmdir "$data/orphan.test";
};

subtest 'a sweep with nothing to do says so' => sub {
    write_config( 'named.test' => 1 );

    my ( $said, $rc ) = says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 0 ) } );
    like( $said, qr/belongs to a guest that is gone/, 'says there is nothing' );
    is( $rc, 0, 'and is not a failure' );
};

subtest 'the sweep finds the data source where _global says it' => sub {

    # Where a configuration says it now.  The sweep read only the data recipe's
    # from, and on a configuration saying it here it swept nothing at all.
    my $dir = $ENV{TROG_PROVISIONER_CONFIG};
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "_base:\n    _global:\n        data_source: $data\nnamed.test:\n    ntp:\n" );
    Provisioner::Cookbook->forget();
    make_path("$data/$_") for qw{orphan.test named.test};

    says( sub { Trog::Skill::Teardown::sweep_orphans( undef, undef, 0 ) } );
    ok( !-e "$data/orphan.test", 'the orphan goes' );
    ok( -d "$data/named.test",   'and the named one stays' );
    File::Path::remove_tree("$data/named.test");
};

subtest 'with no data source, the domain directories are still swept' => sub {
    my $dir     = $ENV{TROG_PROVISIONER_CONFIG};
    my $domains = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "_base:\n    ntp:\n" );
    Provisioner::Cookbook->forget();
    make_path("$domains/orphan.test");

    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { $domains } );
    $hv->redefine( vmm        => sub { bless {}, 'Test::Libvirt' } );
    local @Test::Libvirt::DOMAINS = ();

    my ( $said, $rc ) = says( sub { Trog::Skill::Teardown::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    like( $said, qr/only the domain directories are swept/, 'saying there is no data source' );
    ok( !-e "$domains/orphan.test", 'and sweeping where guests are built all the same' );
    is( $rc, 0, 'which is not a failure' );

    Trog::HV->forget();
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

    like( $text, qr/=item B<--keep-data>/, 'POD documents --keep-data' );
    like( $text, qr/=item B<--orphans>/,   'POD documents --orphans' );
};

done_testing();
