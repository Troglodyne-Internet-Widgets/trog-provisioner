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
    is_deeply( [ $map->('openssl.conf') ],                      ['bin/new_config'],                                                              'and the openssl.conf of its ssl target, for what copies it' );
};

subtest 'a script stands for the tests that name it, and the one that packs it' => sub {
    my @tests = $map->('scripts/setup-ufw-rules');
    ok( ( grep { $_ eq 't/setup-ufw-rules.t' } @tests ), 'its own test' ) or diag "got: @tests";

    @tests = $map->('scripts/escalations.sh');
    ok( ( grep { $_ eq 't/log-watchers.t' } @tests ), 'a test that names it by its file name alone' ) or diag "got: @tests";

    # No test names it, and a script that stands for nothing ran every test.
    is_deeply( [ $map->('scripts/add_to_fstab') ], ['t/new_config-packaging.t'], 'and every script, the test that packs it into the payload' );
};

subtest 'a file that the code reads at run time stands for what reads it' => sub {
    is_deeply( [ $map->('schema/ips.sql') ], ['lib/Provisioner/IPPool.pm'], 'the schema of ips.db, for the pool' );

    my @virtiofs = $map->('virtiofs-better');
    ok( ( grep { $_ eq 'lib/Trog/HV/Libvirt.pm' } @virtiofs ), 'the wrapper of virtiofsd, for the libvirt backend that runs it' ) or diag "got: @virtiofs";

    my @example = $map->('hypervisors.conf.example');
    ok( ( grep { $_ eq 't/hypervisors.t' } @example ), 'and the example fleet, for the test that reads it' ) or diag "got: @example";
};

subtest 'a recipe that no test loads yet stands for the Cookbook that finds it' => sub {
    is_deeply( [ $map->('lib/Provisioner/Recipe/zzprobe.pm') ],        ['lib/Provisioner/Cookbook.pm'], 'a recipe' );
    is_deeply( [ $map->('lib/Provisioner/Recipe/Ubuntu/zzprobe.pm') ], ['lib/Provisioner/Cookbook.pm'], 'and its subclass for a distribution' );
    is_deeply( [ $map->('lib/Trog/Zzprobe.pm') ],                      [],                              'but not any other module' );
};

# The empty string is NO_TESTS in Perl::Tests::Covering.
subtest 'the configuration of the tools reaches no test' => sub {
    foreach my $path (qw{dist.ini weaver.ini .mailmap .perltidyrc .perlcriticrc .perlcriticrc.scripts scripts/.perlcriticrc .preferred_modules.ini .preferred_modules.scripts.ini .preferred_binaries.ini .pod_stopwords}) {
        is_deeply( [ $map->($path) ], [q{}], "$path reaches no test" );
    }

    # The pre-commit hook is shell, and no test loads it.  Left unexplained it
    # ran every test, which answers nothing about a change to it.
    is_deeply( [ $map->('git-hooks/pre-commit') ], [q{}], 'and so does the pre-commit hook' );
};

subtest 'the post-commit hook stands for the test that runs it' => sub {
    my @tests = $map->('git-hooks/post-commit');
    ok( ( grep { $_ eq 't/post-commit.t' } @tests ), 't/post-commit.t' ) or diag "got: @tests";
};

subtest 'documentation reaches no test, and anything else is left to the caller' => sub {
    is_deeply( [ $map->('CLAUDE.md') ],                   [q{}], 'markdown reaches no test' );
    is_deeply( [ $map->('docs/APPROACH.md') ],            [q{}], 'nor does docs/' );
    is_deeply( [ $map->('example.test/provision.conf') ], [q{}], 'nor the example of the configuration of a domain' );
    is_deeply( [ $map->('.gitignore') ],                  [q{}], 'nor .gitignore' );
    is_deeply( [ $map->('.perl-slop.json') ],             [q{}], 'nor the configuration of the gates of perl-slop' );
    is_deeply( [ $map->('.gitattributes') ],              [],    'and .gitattributes is unexplained, so every test runs' );
};

done_testing();
