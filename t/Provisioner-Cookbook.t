#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Cookbook.t - the catalogue: what recipes exist, and what a config for one looks like

=cut

use Test::More;
use Test::MockModule qw{strict};

use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

use Provisioner::Cookbook();

subtest 'the shelf has the recipes on it' => sub {
    my @names = Provisioner::Cookbook->names();

    ok(scalar @names > 20, 'there are a good few');
    is_deeply([sort @names], \@names, 'sorted, so a listing is stable');
    ok((grep { $_ eq 'mariadb' } @names), 'mariadb is one of them');

    # It lives in lib/Provisioner/, not lib/Provisioner/Recipe/, because
    # everything in the latter is discovered and loaded as a recipe.
    ok(!(grep { $_ eq 'Cookbook' } @names), 'and the cookbook is not a recipe');
};

subtest 'has() and load()' => sub {
    ok(Provisioner::Cookbook->has('ntp'), 'a real one');
    ok(!Provisioner::Cookbook->has('nosuchrecipe'), 'and one that is not');

    # Nothing that could reach the filesystem outside the recipe directory.
    ok(!Provisioner::Cookbook->has('../Cookbook'), 'no traversal');
    ok(!Provisioner::Cookbook->has(undef),         'no undef');
    ok(!Provisioner::Cookbook->has(''),            'no empty string');

    is(Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe::ntp', 'loads and names the class');
    isa_ok(Provisioner::Cookbook->load('ntp'), 'Provisioner::Recipe');

    eval { Provisioner::Cookbook->load('nosuchrecipe') };
    like($@, qr/No recipe named 'nosuchrecipe'/, 'says which name it did not know');
    like($@, qr/bin\/recipes/,                   'and where to find the ones it does');
};

subtest 'abstract() reads the file rather than loading it' => sub {
    like(Provisioner::Cookbook->abstract('ntp'), qr/\S/, 'ntp says what it is for');
    is(Provisioner::Cookbook->abstract('nosuchrecipe'), undef, 'and a missing one says nothing');

    my @missing = grep { !defined Provisioner::Cookbook->abstract($_) } Provisioner::Cookbook->names();
    is_deeply(\@missing, [], 'every recipe has an ABSTRACT line') or diag "no abstract: @missing";
};

subtest 'properties() reads what the validator reads, and nothing else' => sub {
    is_deeply(Provisioner::Cookbook->properties({ properties => { a => {} } }), { a => {} }, 'properties');

    # Deliberately not 'parameters'.  OpenAPIv3 ignores it, so offering those
    # fields in a scaffold would claim the recipe checks something it does not.
    is_deeply(Provisioner::Cookbook->properties({ parameters => { b => {} } }), {}, 'not parameters');
    is_deeply(Provisioner::Cookbook->properties({}),    {}, 'neither');
    is_deeply(Provisioner::Cookbook->properties(undef), {}, 'nothing at all');
};

# --- Scaffolding -------------------------------------------------------------
# Against a made-up recipe, so that editing a real one cannot quietly change
# what these assert.
{
    package Provisioner::Recipe::t_scaffold;
    our @ISA = ('Provisioner::Recipe');
    sub args {
        return (
            type     => 'object',
            required => [qw{needed defaulted nested listed}],
            properties => {
                needed    => { type => 'string' },
                defaulted => { type => 'string', default => 'a default' },
                optional  => { type => 'string' },
                opt_dflt  => { type => 'string', default => 'optional default' },
                listed    => { type => 'array', items => { type => 'string' } },
                nested    => {
                    type       => 'object',
                    required   => [qw{inner}],
                    properties => {
                        inner    => { type => 'string' },
                        inner_op => { type => 'string' },
                    },
                },
                bag => { type => 'object', additionalProperties => { type => 'string' } },
            },
        );
    }
}

sub scaffold_of {
    my (%opts) = @_;
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine(load => sub { 'Provisioner::Recipe::t_scaffold' });
    return Provisioner::Cookbook->scaffold('t_scaffold', %opts);
}

subtest 'a scaffold is the smallest thing that could work' => sub {
    my ($config, @todo) = scaffold_of();

    is($config->{defaulted}, 'a default', 'a required field with a default gets it');
    is($config->{needed}, Provisioner::Cookbook->PLACEHOLDER, 'and one without gets a placeholder');

    ok(!exists $config->{optional}, 'optional fields are left out');
    ok(!exists $config->{opt_dflt},
        'including ones with defaults, so the recipe default keeps applying rather than being frozen here');

    is_deeply($config->{nested}, { inner => Provisioner::Cookbook->PLACEHOLDER },
        'a required object is scaffolded through, required fields only');
    is_deeply($config->{listed}, [Provisioner::Cookbook->PLACEHOLDER], 'an array gets one item to copy');

    is_deeply([sort @todo], [qw{t_scaffold.listed[0] t_scaffold.needed t_scaffold.nested.inner}],
        'and the paths that need a human come back, defaults not among them');
};

subtest 'all => 1 is the full menu' => sub {
    my ($config) = scaffold_of(all => 1);

    is($config->{opt_dflt}, 'optional default', 'optional fields appear, with their defaults');
    is($config->{optional}, Provisioner::Cookbook->PLACEHOLDER, 'and without');
    is($config->{nested}{inner_op}, Provisioner::Cookbook->PLACEHOLDER, 'through nested objects too');
};

subtest 'provided fields are left alone' => sub {
    # _base wins the merge, so writing a placeholder over something it supplies
    # would be silently discarded rather than stopping anything.
    my ($config, @todo) = scaffold_of(provided => { needed => 'from _base' });

    ok(!exists $config->{needed}, 'not written');
    ok(!(grep { index($_, 'needed') >= 0 } @todo), 'and not asked about');
    is($config->{defaulted}, 'a default', 'the rest is unaffected');
};

subtest 'a recipe that needs nothing gets nothing' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine(load => sub { 'Provisioner::Recipe' });    # args() returns ()

    my ($config, @todo) = Provisioner::Cookbook->scaffold('anything');
    is($config, undef, 'undef, which is how the config files spell it: a bare key');
    is_deeply(\@todo, [], 'and nothing to do');
};

subtest 'defaults are copied, not shared' => sub {
    my ($one) = scaffold_of();
    my ($two) = scaffold_of();
    push @{ $one->{listed} }, 'mutated';
    is(scalar @{ $two->{listed} }, 1, 'one scaffold cannot reach into the next');
};

# --- Finding what is left ----------------------------------------------------
subtest 'placeholders_in walks the whole structure' => sub {
    my $ph = Provisioner::Cookbook->PLACEHOLDER;

    is_deeply([Provisioner::Cookbook->placeholders_in({
        mariadb => { root_pw => $ph, version => '10.11', flags => ['ok', $ph] },
        ufw     => undef,
        nested  => { a => { b => $ph } },
    })],
    [qw{mariadb.flags[1] mariadb.root_pw nested.a.b}],
        'hashes, arrays and undefs alike');

    is_deeply([Provisioner::Cookbook->placeholders_in({ a => 1, b => 'fine' })], [],
        'and says nothing when there is nothing left');

    is_deeply([Provisioner::Cookbook->placeholders_in($ph)], [''], 'a bare placeholder is its own path');
};

subtest 'every real recipe can be loaded and scaffolded' => sub {
    # A recipe may compute a default by asking the internet -- garage asks
    # GitHub for the current release.  Scaffolding has to work without a
    # network, and a test suite has no business making the call, so there is
    # not one to make.
    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine(get => sub { { success => 0, status => 599, content => '' } });

    my @broken;
    foreach my $name (Provisioner::Cookbook->names()) {
        eval {
            my ($config, @todo) = Provisioner::Cookbook->scaffold($name);
            Provisioner::Cookbook->spec($name);
            1;
        } or push @broken, "$name: $@";
    }
    is_deeply(\@broken, [], 'all of them') or diag join "\n", @broken;
};

subtest 'no recipe declares its fields somewhere the validator will not look' => sub {
    # An object schema spells its fields "properties".  Spell it "parameters"
    # and OpenAPIv3 skips the lot: the recipe looks validated, accepts anything,
    # and says nothing.  Seven did.  This is why they do not any more.
    my $http = Test::MockModule->new('HTTP::Tiny');
    $http->redefine(get => sub { { success => 0, status => 599, content => '' } });

    my @wrong;
    foreach my $name (Provisioner::Cookbook->names()) {
        my %spec = Provisioner::Cookbook->spec($name);
        push @wrong, map { "$name: $_" } stray_parameters(\%spec, q{});
    }
    is_deeply(\@wrong, [], 'every schema says properties') or diag join "\n", @wrong;
};

# Anywhere in a schema that a "parameters" key sits where "properties" belongs.
sub stray_parameters {
    my ($node, $path) = @_;

    my $ref = ref $node;
    return map { stray_parameters($node->[$_], "$path\[$_]") } 0 .. $#$node if $ref eq 'ARRAY';
    return () unless $ref eq 'HASH';

    my @found;
    push @found, ($path eq q{} ? '(top level)' : $path) if exists $node->{parameters};
    push @found, map { stray_parameters($node->{$_}, $path eq q{} ? $_ : "$path.$_") } sort keys %$node;
    return @found;
}

done_testing();
