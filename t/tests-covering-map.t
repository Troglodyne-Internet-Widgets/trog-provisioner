#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/tests-covering-map.t - .tests-covering-map.pl: which tests reach a file that
no test loads

=cut

use Test::More;
use File::Find();
use FindBin;
use FindBin::libs;

# The map answers with paths relative to the root, as tests-covering runs it.
chdir "$FindBin::Bin/.." or BAIL_OUT("Cannot enter the root: $!");

my $map = do './.tests-covering-map.pl';
is( ref $map, 'CODE', 'the map is a code reference' ) or BAIL_OUT( 'the map did not load: ' . ( $@ || $! ) );

subtest 'every template stands for something' => sub {

    # A template that no recipe names runs every test, and says nothing about
    # why.  The usual cause is a template that is renamed, or that is new and
    # not yet in template_files.
    my @templates;
    File::Find::find( { no_chdir => 1, wanted => sub { push @templates, $File::Find::name unless -d $File::Find::name } }, 'templates' );
    ok( scalar @templates, 'there are templates to ask about' );

    my @unplaced = grep { !$map->($_) } @templates;
    is( "@unplaced", '', 'each one stands for a file' ) or diag "no recipe names: @unplaced";
};

subtest 'a template stands for the recipe that renders it' => sub {
    is_deeply( [ $map->('templates/ubuntu/nginxdirindex.tt') ], ['lib/Provisioner/Recipe/nginxdirindex.pm'],                                     'its own fragment' );
    is_deeply( [ $map->('templates/files/tpsgi.tt') ],          [ 'lib/Provisioner/Recipe/Ubuntu/tpsgi.pm', 'lib/Provisioner/Recipe/tpsgi.pm' ], 'a file from template_files, with the subclass of the distribution' );
    is_deeply( [ $map->('templates/tests/nginxdirindex.tt') ],  ['lib/Provisioner/Recipe/nginxdirindex.pm'],                                     'and its guest test' );
    is_deeply( [ $map->('templates/makefile.tt') ],             ['bin/new_config'],                                                              'the makefile, for what renders it' );
};

subtest 'a script on the system perl stands for the tests that name it' => sub {
    my @tests = $map->('scripts/setup-ufw-rules');
    ok( ( grep { $_ eq 't/setup-ufw-rules.t' } @tests ), 'its own test' ) or diag "got: @tests";
};

subtest 'documentation reaches no test, and anything else is left to the caller' => sub {
    is_deeply( [ $map->('CLAUDE.md') ],        ['CLAUDE.md'],        'markdown stands for itself' );
    is_deeply( [ $map->('docs/APPROACH.md') ], ['docs/APPROACH.md'], 'as does docs/' );
    is_deeply( [ $map->('dist.ini') ],         [],                   'and dist.ini is unexplained, so every test runs' );
};

done_testing();
