#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-backup.t - which targets a backup serves, and which ones
its destination asks for

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Path       qw{make_path};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use File::Slurper::Temp();

use Provisioner::Cookbook();

# Two recipes the loop requires by name.  One has two paths and a pattern that
# must not travel, and the other has one path and none.
{

    package Provisioner::Recipe::t_twopaths;
    use parent -norequire, qw{Provisioner::Recipe};
    sub remote_files { my ( $self, $install_dir ) = @_; return ( "$install_dir/b" => 'b', "$install_dir/a" => 'a' ) }
    sub remote_skip  { return ( 'key.pem', 'cache/' ) }

    package Provisioner::Recipe::t_onepath;
    use parent -norequire, qw{Provisioner::Recipe};
    sub remote_files { return ( '/bogus/only' => 'only' ) }
}
$INC{'Provisioner/Recipe/t_twopaths.pm'} = __FILE__;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- for the life of the test, as a use would leave it
$INC{'Provisioner/Recipe/t_onepath.pm'}  = __FILE__;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- for the life of the test, as a use would leave it

my @MODULES = qw{t_twopaths t_onepath};

sub recipe {
    my ($name) = @_;
    return Provisioner::Cookbook->load($name)->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
    );
}

subtest 'default_targets numbers each recipe paths in order' => sub {
    my @targets = recipe('backup')->default_targets( modules => \@MODULES, install_dir => '/bogus/dir', domain => 'a.test' );

    is_deeply(
        \@targets,
        [
            { name => 't_twopaths1', path => '/bogus/dir/a', skip => 'key.pem cache/' },
            { name => 't_twopaths2', path => '/bogus/dir/b', skip => 'key.pem cache/' },
            { name => 't_onepath1',  path => '/bogus/only',  skip => q{} },
        ],
        'one target per path, named for its recipe and numbered in sorted path order'
    ) or diag explain \@targets;
};

subtest 'the backup and its destination name the same targets' => sub {
    my $utils = Test::MockModule->new('Provisioner::Utils');
    $utils->redefine( ssh_pubkey_from_private => sub { return 'ssh-ed25519 AAAA bogus' } );

    my $data = tempdir( CLEANUP => 1 );
    make_path("$data/a.test");
    File::Slurper::Temp::write_text( "$data/a.test/key", q{} );

    my %common = ( modules => \@MODULES, install_dir => '/bogus/dir', domain => 'a.test', data_source => $data, key_file => 'key' );

    my %source = recipe('backup')->validate(
        %common,
        targets  => { extra       => '/bogus/extra' },
        excludes => { t_twopaths1 => 'tmp/' },
    );
    my %destination = recipe('backupdestination')->validate(
        %common,
        base_dir => '/bogus/backups',
        hosts    => ['a.test'],
        targets  => ['extra'],
    );

    is_deeply( [ sort keys %{ $source{targets} } ], [ sort @{ $destination{targets} } ], 'the destination asks for every module the source serves' );

    is( $source{excludes}{t_twopaths1}, 'key.pem cache/ tmp/', 'what a recipe says must not travel is added to what the operator excluded' );
    is( $source{excludes}{t_twopaths2}, 'key.pem cache/',      'and applies to a target the operator said nothing about' );
    ok( !exists $source{excludes}{t_onepath1}, 'while a recipe with nothing to skip gets no exclude' );

    my %unexcluded = recipe('backup')->validate( %common, targets => {} );
    is( $unexcluded{excludes}{t_twopaths1}, 'key.pem cache/', 'with no excludes configured, the schema default still takes what the recipes skip' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
