#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

# A -f in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

=head1 NAME

t/new_guest.t - bin/new_guest and bin/recipes, the two front ends to the cookbook

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();
use IPC::Run3();

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

my $script = "$FindBin::Bin/../bin/new_guest";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# These print their progress to stderr; the tests do not need to read it.
sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $err) or die $!;
    my @result = do { local *STDERR = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

sub run_bin {
    my ($bin, @args) = @_;
    my $out = q{};
    my $err = q{};
    IPC::Run3::run3([$^X, "-I$FindBin::Bin/../lib", "$FindBin::Bin/../bin/$bin", @args],
        \undef, \$out, \$err);
    return ($out, $err, $? >> 8);
}

subtest 'a default hostname is unique, and under a TLD reserved for this' => sub {
    my $one = Trog::Bin::NewGuest::default_hostname();
    my $two = Trog::Bin::NewGuest::default_hostname();

    like($one, qr/\A[0-9a-f-]{36}\.test\z/, 'a UUID under .test');
    isnt($one, $two, 'and a different one each time');
};

subtest 'the domain block asks the hypervisor for enough to build with' => sub {
    my ($config) = Trog::Bin::NewGuest::build('vm.test', ['ntp'], {});
    my $global = $config->{'vm.test'}{_global};

    # 8092 and 4, not the 2048 and 2 this scaffolded before.  A domain carrying
    # the perl recipe builds perl from source and installs Perl::Critic and
    # friends with their test suites; in 2GB that thrashes rather than fails,
    # and a provision takes hours with nothing in any log to say why.
    is($global->{memory}, 8092,              'memory');
    is($global->{cpus},   4,                 'cpus');
    is($global->{size},   20 * 1024**3,      'and 20GB of disk');
    ok(!exists $global->{user}, 'no service account unless asked for: a scratch guest wants none');

    ($config) = Trog::Bin::NewGuest::build('vm.test', ['ntp'],
        { memory => 8192, cpus => 8, size => 42, user => 'someone' });
    is_deeply($config->{'vm.test'}{_global},
        { memory => 8192, cpus => 8, size => 42, user => 'someone' }, 'all overridable');
};

my %BASE_HAS_DATA = (base => { data => { from => '/opt/data', to => '/opt/domains' } });

subtest 'recipes that need nothing are a bare key' => sub {
    my ($config, @todo) = Trog::Bin::NewGuest::build('vm.test', [qw{ntp ufw}], \%BASE_HAS_DATA);

    ok(exists $config->{'vm.test'}{ntp}, 'the recipe is there');
    is($config->{'vm.test'}{ntp}, undef,  'with nothing under it, as the config files spell it');
    is_deeply(\@todo, [], 'and nothing to fill in');
};

subtest 'recipes that need something say so' => sub {
    my ($config, @todo) = Trog::Bin::NewGuest::build('vm.test', ['mariadb'], \%BASE_HAS_DATA);

    is($config->{'vm.test'}{mariadb}{root_pw}, 'CHANGEME', 'a placeholder for each');
    is_deeply([sort @todo], [qw{mariadb.dumpfile mariadb.root_pw mariadb.version}],
        'and the paths come back so they can be printed');
};

subtest 'every domain gets a data recipe, because new_config requires one' => sub {
    my ($config) = Trog::Bin::NewGuest::build('vm.test', ['ntp'], {});
    ok(exists $config->{'vm.test'}{data}, 'added even though it was not asked for');

    # But not when _base already configures it.  _base wins the merge, so
    # writing placeholders over it would be silently discarded rather than
    # stopping anything -- worse than not writing them.
    ($config) = Trog::Bin::NewGuest::build('vm.test', ['ntp'],
        { base => { data => { from => '/opt/data', to => '/opt/domains' } } });
    ok(!exists $config->{'vm.test'}{data}, 'left to _base when _base has it');
};

subtest 'base_config reads _base out of recipes.yaml' => sub {
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    is_deeply(Trog::Bin::NewGuest::base_config(), {}, 'no recipes.yaml at all is not an error');

    File::Slurper::Temp::write_text("$dir/recipes.yaml", "---\nnot a hash of what we want\n");
    is_deeply(Trog::Bin::NewGuest::base_config(), {}, 'nor is one with no _base');

    File::Slurper::Temp::write_text("$dir/recipes.yaml", "---\n_base:\n  data:\n    from: /opt/data\n");
    is_deeply(Trog::Bin::NewGuest::base_config(), { data => { from => '/opt/data' } }, 'and it reads');
};

# --- End to end --------------------------------------------------------------
subtest 'writing a guest' => sub {
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    is(quietly(sub { Trog::Bin::NewGuest::main(qw{--hostname scratch.test ntp ufw}) }), 0, 'runs');

    my $written = "$dir/recipes.d/scratch.test.yaml";
    ok(-f $written, 'wrote where Trog::Config says configuration lives');

    my $config = YAML::XS::Load(File::Slurper::read_text($written));
    is_deeply([sort keys %{ $config->{'scratch.test'} }], [qw{_global data ntp ufw}],
        'the domain, its recipes, and the data every domain needs');

    # A hostname collision is the usual reason to find a file already there,
    # and quietly replacing somebody's configuration is not a good answer.
    eval { quietly(sub { Trog::Bin::NewGuest::main(qw{--hostname scratch.test ntp}) }) };
    like($@, qr/already there/, 'refuses to overwrite');
    like($@, qr/--force/,       'and says what to do about it');

    is(quietly(sub { Trog::Bin::NewGuest::main(qw{--force --hostname scratch.test ntp}) }), 0,
        '--force does it');
};

subtest 'it checks every recipe name before writing any of the file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    eval { quietly(sub { Trog::Bin::NewGuest::main(qw{--hostname x.test ntp nosuchrecipe alsobogus}) }) };
    like($@, qr/'nosuchrecipe'/, 'names the bad one');
    like($@, qr/'alsobogus'/,    'and the other one, rather than stopping at the first');
    ok(!-e "$dir/recipes.d/x.test.yaml", 'and wrote nothing');
};

subtest 'a hostname has to be one' => sub {
    eval { quietly(sub { Trog::Bin::NewGuest::main(qw{--stdout --hostname bare ntp}) }) };
    like($@, qr/not a fully qualified domain name/, 'a bare label is refused');
};

subtest 'the document goes to stdout and the commentary to stderr' => sub {
    my ($out, $err, $rc) = run_bin(qw{new_guest --stdout --hostname piped.test mariadb});

    is($rc, 0, 'exits clean');
    my $config = YAML::XS::Load($out);
    ok(exists $config->{'piped.test'}, 'stdout is the document, and nothing else') or diag $out;

    like($err, qr/Fill these in/,        'stderr says what is left');
    like($err, qr/mariadb\.root_pw/,     'naming it');
    like($err, qr/bin\/provision piped\.test/, 'and what to run next');
};

# --- bin/recipes -------------------------------------------------------------
subtest 'bin/recipes lists them' => sub {
    my ($out, $err, $rc) = run_bin('recipes');
    is($rc, 0, 'exits clean');

    my @lines = split("\n", $out);
    ok(scalar @lines > 20, 'a good few');
    like($out, qr/^ntp\s+\S/m, 'each with what it is for');
};

subtest 'bin/recipes --json is machine readable' => sub {
    my ($out, $err, $rc) = run_bin('recipes', '--json');
    is($rc, 0, 'exits clean');

    my $listing = eval { Cpanel::JSON::XS->new->decode($out) };
    is(ref $listing, 'ARRAY', 'an array') or diag $@;
    ok((grep { $_->{name} eq 'ntp' && $_->{abstract} } @$listing), 'of names and abstracts');
};

subtest 'bin/recipes NAME dumps the schema' => sub {
    my ($out, $err, $rc) = run_bin('recipes', 'mariadb');
    is($rc, 0, 'exits clean');

    my $spec = eval { Cpanel::JSON::XS->new->decode($out) };
    is($spec->{type}, 'object', 'the args() schema, as JSON') or diag $@;
    is_deeply([sort @{ $spec->{required} }], [qw{dumpfile root_pw version}], 'required and all');
};

subtest 'bin/recipes on a name that is not one' => sub {
    my ($out, $err, $rc) = run_bin('recipes', 'nosuchrecipe');
    isnt($rc, 0, 'fails');
    like($err, qr/No recipe named 'nosuchrecipe'/, 'saying so');
    like($err, qr/bin\/recipes/, 'and where to look');
};

subtest 'bin/recipes --scaffold shows what new_guest would write' => sub {
    my ($out, $err, $rc) = run_bin(qw{recipes --scaffold mariadb});
    is($rc, 0, 'exits clean');

    my $got = eval { Cpanel::JSON::XS->new->decode($out) };
    is($got->{configuration}{mariadb}{root_pw}, 'CHANGEME', 'the configuration') or diag $@;
    is_deeply($got->{needs_filling}, [qw{mariadb.dumpfile mariadb.root_pw mariadb.version}], 'and the todo list');
};

done_testing();
