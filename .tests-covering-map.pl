package Trog::TestsCoveringMap;    ## no critic (Modules::RequireFilenameMatchesPackage) -- tests-covering looks for this file by this name at the root

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

Trog::TestsCoveringMap - which tests reach the files that no test loads, for
tests-covering

=head1 DESCRIPTION

This is F<.tests-covering-map.pl>.  C<tests-covering> finds it at the root, and
git-hooks/pre-commit asks it which tests a commit can break.  It follows the
Perl that each test loads.  This map answers for the files it cannot follow.  See "THE MAP" in
L<Perl::Tests::Covering>.

=over

=item A template

A template stands for the recipe that renders it, so the tests that load the
recipe are chosen.  Each recipe names its templates: its fragment and its
global fragment, the keys of C<template_files>, and C<tests> under
F<templates/tests/>.  Each name is looked for in every directory of
C<template_dirs>.  F<templates/makefile.tt> stands for F<bin/new_config>, which
renders it.

=item A script under F<scripts/>

A script that starts with C<#!/usr/bin/perl> runs on the system perl, which
cannot record what it loads.  It stands for each test that names it.

=item A new recipe

L<Provisioner::Cookbook> finds recipes at run time, so nothing in a diff uses a
new one.  A recipe that no test loads yet stands for the Cookbook.

=item Documentation

Markdown, F<docs/>, F<LICENSE> and F<CHANGES> reach no test.

=item Configuration of the tools

F<dist.ini>, F<weaver.ini>, F<.mailmap>, F<.perltidyrc>, the C<perlcritic>
profiles and the files that they read reach no test.  The pre-commit hook runs
C<perltidy> and C<perlcritic> itself, and no test reads these files from this
checkout.

=back

Anything else is left unexplained, and the hook then runs every test.

=cut

use File::Spec();
use File::Temp();
use Provisioner::Cookbook();

# Read by the tools that the hook runs, and by dzil, and by no test.
my %TOOL_CONFIGURATION = map { $_ => 1 } qw{
  dist.ini weaver.ini .mailmap .perltidyrc .perlcriticrc .perlcriticrc.scripts
  scripts/.perlcriticrc .preferred_modules.ini .preferred_modules.scripts.ini
  .preferred_binaries.ini .pod_stopwords
};

# The path of each template, relative to the root, and the files that stand for
# it.  Built on the first call, because loading every recipe takes a second.
my %stands_for;

sub _templates_of_recipes {
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    my @names   = ( Provisioner::Cookbook->names, Provisioner::Cookbook->distros, 'vm' );

    my %found;
    foreach my $distro ( Provisioner::Cookbook->distros ) {
        my @dirs = map { File::Spec->abs2rel($_) } @{ Provisioner::Cookbook->template_dirs($distro) };

        foreach my $name (@names) {
            my $class  = Provisioner::Cookbook->load( $name, distro => $distro );
            my $recipe = $class->new(
                distro          => $distro,
                target_packager => 'deb',
                template_dirs   => Provisioner::Cookbook->template_dirs($distro),

                # ufw clears a directory under this in template_files.
                output_dir => $scratch,
            );

            # Every recipe, so that ufw names the profile of each.
            my %files         = $recipe->template_files(@names);
            my @names_in_dirs = ( @{$recipe}{qw{template global_template}}, map { "files/$_" } keys %files );

            # The recipe and its distribution's subclass, if it has one.
            my @modules = grep { -e } map { "lib/$_.pm" =~ s{::}{/}gr } $class, "Provisioner::Recipe::$name";

            foreach my $dir (@dirs) {
                push @{ $found{"$dir/$_"} }, @modules for @names_in_dirs;
            }
            push @{ $found{"templates/tests/$_"} }, @modules for $recipe->tests;
        }
    }

    $found{'templates/makefile.tt'} = ['bin/new_config'];
    return %found;
}

sub _tests_that_name {
    my ($script) = @_;

    my @tests;
    foreach my $test ( glob 't/*.t' ) {
        open( my $fh, '<', $test ) or die "Cannot read $test: $!";
        my $source = do { local $/; <$fh> };
        close($fh) or die "Cannot close $test: $!";
        push @tests, $test if index( $source, $script ) >= 0;
    }
    return @tests;
}

return sub {
    my ($path) = @_;

    # NO_TESTS in Perl::Tests::Covering, spelled out so that the test of this
    # map does not need the module.
    return q{} if $path =~ m{(?:[.]md|\ALICENSE|\ACHANGES)\z} || $path =~ m{\Adocs/};

    # Before the scripts, because scripts/.perlcriticrc is a link to the profile.
    return q{} if $TOOL_CONFIGURATION{$path};

    if ( $path =~ m{\Atemplates/} ) {
        %stands_for = _templates_of_recipes() unless %stands_for;
        my %unique = map { $_ => 1 } @{ $stands_for{$path} // [] };
        my @unique = sort keys %unique;
        return @unique;
    }

    return _tests_that_name($path) if $path =~ m{\Ascripts/[^/]+\z};

    return 'lib/Provisioner/Cookbook.pm' if $path =~ m{\Alib/Provisioner/Recipe/.+[.]pm\z};

    return;
};
