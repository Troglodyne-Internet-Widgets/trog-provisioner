#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# A -f in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

=head1 NAME

t/new_guest.t - bin/new_guest and bin/recipes, the two front ends to the cookbook

=cut

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stderr};
use FindBin;
use FindBin::libs;
use Provisioner::Cookbook();
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();
use IPC::Run3();

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

my $script = "$FindBin::Bin/../bin/new_guest";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

# These print their progress to stderr; the tests do not need to read it.
sub quietly {
    my ($code) = @_;
    my ( undef, @result ) = capture_stderr { $code->() };
    return wantarray ? @result : $result[0];
}

sub run_bin {
    my ( $bin, @args ) = @_;
    my $out = q{};
    my $err = q{};
    IPC::Run3::run3(
        [ $^X, "-I$FindBin::Bin/../lib", "$FindBin::Bin/../bin/$bin", @args ],
        \undef, \$out, \$err
    );
    return ( $out, $err, $? >> 8 );
}

subtest 'a default hostname is unique, and under a TLD reserved for this' => sub {
    my $one = Trog::Bin::NewGuest::default_hostname();
    my $two = Trog::Bin::NewGuest::default_hostname();

    like( $one, qr/\A[\da-f-]{36}\.test\z/, 'a UUID under .test' );
    isnt( $one, $two, 'and a different one each time' );
};

subtest 'the domain block asks the hypervisor for enough to build with' => sub {
    my ($config) = Trog::Bin::NewGuest::build( 'vm.test', ['ntp'], {} );
    my $global = $config->{'vm.test'}{_global};

    # The vm recipe's, rather than a second set of numbers here: a domain block
    # that leaves these out gets exactly the same guest, because bin/new_config
    # falls back to the same schema.  The reason for these particular ones is
    # written down where they now live.
    my %vm = Provisioner::Cookbook->defaults('vm');
    is( $global->{memory}, $vm{memory}, 'memory is the vm recipe default' );
    is( $global->{cpus},   $vm{cpus},   'as are cpus' );
    is( $global->{size},   $vm{size},   'and the disk' );

    # And they are the ones that matter, said once so that changing them here
    # is a deliberate act rather than a drift.
    is( $vm{memory}, 8092,         'enough memory to build perl in' );
    is( $vm{cpus},   4,            'and enough CPUs' );
    is( $vm{size},   40 * 1024**3, 'on a 40GB overlay' );
    ok( !exists $global->{user}, 'no service account unless asked for: a scratch guest wants none' );

    ($config) = Trog::Bin::NewGuest::build(
        'vm.test', ['ntp'],
        { memory => 8192, cpus => 8, size => 42, user => 'someone' }
    );
    is_deeply(
        $config->{'vm.test'}{_global},
        { memory => 8192, cpus => 8, size => 42, user => 'someone' }, 'all overridable'
    );
};

# A bare key, which is how a configuration names a recipe that takes nothing:
# what matters to new_guest is that _base mentions data at all.
my %BASE_HAS_DATA = ( base => { data => undef } );

subtest 'recipes that need nothing are a bare key' => sub {
    my ( $config, @todo ) = Trog::Bin::NewGuest::build( 'vm.test', [qw{ntp ufw}], \%BASE_HAS_DATA );

    ok( exists $config->{'vm.test'}{ntp}, 'the recipe is there' );
    is( $config->{'vm.test'}{ntp}, undef, 'with nothing under it, as the config files spell it' );
    is_deeply( \@todo, [], 'and nothing to fill in' );
};

subtest 'recipes that need something say so' => sub {
    my ( $config, @todo ) = Trog::Bin::NewGuest::build( 'vm.test', ['mariadb'], \%BASE_HAS_DATA );

    is( $config->{'vm.test'}{mariadb}{root_pw}, 'CHANGEME', 'a placeholder for each' );
    is_deeply(
        [ sort @todo ], [qw{mariadb.dumpfile mariadb.root_pw mariadb.version}],
        'and the paths come back so they can be printed'
    );
};

subtest 'a dependency that needs something says so as well' => sub {

    # What is scaffolded above is the recipes on the command line.  What the
    # guest is built from is that set closed over required_recipes, and grafana
    # arrives that way wanting an admin_password nothing hands it -- a password
    # not being something a depending recipe can choose for an operator.  Before
    # this, the report said there was nothing to fill in and new_config refused
    # once a guest was already going up.
    my ( $config, @todo ) = Trog::Bin::NewGuest::build( 'vm.test', ['grafanasyslog'], \%BASE_HAS_DATA );

    is( $config->{'vm.test'}{grafana}{admin_password}, 'CHANGEME', 'the dependency gets a block to hold the value' );
    ok( ( grep { $_ eq 'grafana.admin_password' } @todo ), 'and the path is printed with the rest' )
      or diag "todo was: @todo";

    # Restraint is the other half.  nginxproxy and logcollector are pulled in by
    # the same expansion and both are satisfied by whoever asked for them, so
    # neither is written here: the depsolver adds the recipe, and a block exists
    # only to hold a value somebody has to supply.
    ok( !exists $config->{'vm.test'}{nginxproxy},   'a dependency that wants nothing is left to the depsolver' );
    ok( !exists $config->{'vm.test'}{logcollector}, 'as is one whose requirer supplied what it needed' );
};

subtest 'a recipe that salvages something can still be scaffolded' => sub {

    # Provisioner::Recipe::required_recipes asks restores() what goes back, and
    # Provisioner::Cookbook asks that at scaffold time.  letsencrypt and pdns
    # both interpolate the domain into the paths they restore, so a scaffold
    # walk without the domain dies on the undef under `warnings FATAL => 'all'`.
    # None of the recipes scaffolded above declares a restores().
    my ($config) = Trog::Bin::NewGuest::build( 'vm.test', ['letsencrypt'], \%BASE_HAS_DATA );

    ok( exists $config->{'vm.test'}{letsencrypt}, 'the recipe is scaffolded rather than taking the run down' );
};

subtest 'a recipe whose dependencies are built from the domain can be scaffolded' => sub {

    # tpsgi builds the path that perl installs from out of install_dir and the
    # domain.  No _base can name the domain, and this one names no install_dir.
    my ( $config, @todo ) = Trog::Bin::NewGuest::build( 'vm.test', ['tpsgi'], {} );

    ok( exists $config->{'vm.test'}{tpsgi},          'tpsgi is scaffolded' );
    ok( ( grep { $_ eq 'tpsgi.routers[0]' } @todo ), 'and asks for its routers' ) or diag "todo was: @todo";
};

subtest 'every domain gets a data recipe, because new_config requires one' => sub {
    my ($config) = Trog::Bin::NewGuest::build( 'vm.test', ['ntp'], {} );
    ok( exists $config->{'vm.test'}{data}, 'added even though it was not asked for' );

    # But not when _base already configures it: there is nothing to fill in, and
    # a generated file that pins what the fleet supplies is a file that stops
    # following it.
    ($config) = Trog::Bin::NewGuest::build( 'vm.test', ['ntp'], { base => { data => undef } } );
    ok( !exists $config->{'vm.test'}{data}, 'left to _base when _base has it' );
};

subtest 'base_config reads _base out of recipes.yaml' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    is_deeply( Trog::Bin::NewGuest::base_config(), {}, 'no recipes.yaml at all is not an error' );

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\nsome.test.test:\n  ntp:\n" );
    Provisioner::Cookbook->forget();
    is_deeply( Trog::Bin::NewGuest::base_config(), {}, 'nor is one with no _base' );

    File::Slurper::Temp::write_text( "$dir/recipes.yaml", "---\n_base:\n  ntp:\n    pool: base.pool\n  _global:\n    data_source: /bogus/data\n" );
    Provisioner::Cookbook->forget();
    is_deeply(
        Trog::Bin::NewGuest::base_config(),
        { ntp => { pool => 'base.pool' }, _global => { data_source => '/bogus/data' } },
        'and it reads, _global and all'
    );

    # A domain file cannot say what every guest gets.
    mkdir("$dir/recipes.d") or die "Could not make $dir/recipes.d: $!";
    File::Slurper::Temp::write_text( "$dir/recipes.d/other.test.test.yaml", "---\n_base:\n  ufw:\n" );
    Provisioner::Cookbook->forget();
    ok( !exists Trog::Bin::NewGuest::base_config()->{ufw}, 'and _base in recipes.d is not part of it' );
    Provisioner::Cookbook->forget();
};

# --- End to end --------------------------------------------------------------
subtest 'writing a guest' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    is( quietly( sub { Trog::Bin::NewGuest::main(qw{--hostname scratch.test ntp ufw}) } ), 0, 'runs' );

    my $written = "$dir/recipes.d/scratch.test.yaml";
    ok( -f $written, 'wrote where Trog::Config says configuration lives' );

    my $config = YAML::XS::Load( File::Slurper::read_text($written) );
    is_deeply(
        [ sort keys %{ $config->{'scratch.test'} } ], [qw{_global data ntp ufw}],
        'the domain, its recipes, and the data every domain needs'
    );

    # A hostname collision is the usual reason to find a file already there,
    # and quietly replacing somebody's configuration is not a good answer.
    my $err = exception {
        quietly( sub { Trog::Bin::NewGuest::main(qw{--hostname scratch.test ntp}) } )
    };
    like( $err, qr/already[ ]there/, 'refuses to overwrite' );
    like( $err, qr/--force/,         'and says what to do about it' );

    is(
        quietly( sub { Trog::Bin::NewGuest::main(qw{--force --hostname scratch.test ntp}) } ), 0,
        '--force does it'
    );
};

subtest 'it checks every recipe name before writing any of the file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my $err = exception {
        quietly( sub { Trog::Bin::NewGuest::main(qw{--hostname x.test ntp nosuchrecipe alsobogus}) } )
    };
    like( $err, qr/'nosuchrecipe'/, 'names the bad one' );
    like( $err, qr/'alsobogus'/,    'and the other one, rather than stopping at the first' );
    ok( !-e "$dir/recipes.d/x.test.yaml", 'and wrote nothing' );
};

subtest 'a hostname has to be one' => sub {
    like(
        exception {
            quietly( sub { Trog::Bin::NewGuest::main(qw{--stdout --hostname bare ntp}) } )
        },
        qr/not[ ]a[ ]fully[ ]qualified[ ]domain[ ]name/,
        'a bare label is refused'
    );
};

subtest 'the document goes to stdout and the commentary to stderr' => sub {
    my ( $out, $err, $rc ) = run_bin(qw{new_guest --stdout --hostname piped.test mariadb});

    is( $rc, 0, 'exits clean' );
    my $config = YAML::XS::Load($out);
    ok( exists $config->{'piped.test'}, 'stdout is the document, and nothing else' ) or diag $out;

    like( $err, qr/Fill[ ]these[ ]in/,            'stderr says what is left' );
    like( $err, qr/mariadb\.root_pw/,             'naming it' );
    like( $err, qr/bin\/provision[ ]piped\.test/, 'and what to run next' );
};

# --- bin/recipes -------------------------------------------------------------
subtest 'bin/recipes lists them' => sub {
    my ( $out, undef, $rc ) = run_bin('recipes');
    is( $rc, 0, 'exits clean' );

    my @lines = split( m/\n/, $out );
    ok( scalar @lines > 20, 'a good few' );
    like( $out, qr/^ntp\s+\S/m, 'each with what it is for' );
};

subtest 'bin/recipes --json is machine readable' => sub {
    my ( $out, undef, $rc ) = run_bin( 'recipes', '--json' );
    is( $rc, 0, 'exits clean' );

    my $listing = eval { Cpanel::JSON::XS->new->decode($out) };
    is( ref $listing, 'ARRAY', 'an array' ) or diag $@;
    ok( ( grep { $_->{name} eq 'ntp' && $_->{abstract} } @$listing ), 'of names and abstracts' );
};

subtest 'bin/recipes NAME dumps the schema' => sub {
    my ( $out, undef, $rc ) = run_bin( 'recipes', 'mariadb' );
    is( $rc, 0, 'exits clean' );

    my $spec = eval { Cpanel::JSON::XS->new->decode($out) };
    is( $spec->{type}, 'object', 'the args() schema, as JSON' ) or diag $@;
    is_deeply( [ sort @{ $spec->{required} } ], [qw{dumpfile root_pw version}], 'required and all' );
};

subtest 'bin/recipes NAME says what it downloads from' => sub {
    my ( $out, $err, $rc ) = run_bin( 'recipes', 'perllsp' );
    is( $rc, 0, 'exits clean' );

    # The hosts a guest points at the fetch cache while it provisions.
    my $spec = eval { Cpanel::JSON::XS->new->decode($out) };
    is_deeply( $spec->{'x-fetch-hosts'}, ['codeload.github.com'], 'its fetch_hosts' ) or diag $@;

    # A recipe that cannot fetch rather than one that happens not to today:
    # this was mariadb until mariadb declared the host it takes its signing key
    # from, and the test broke for a reason that had nothing to do with what it
    # is checking.  ufw writes firewall rules and will never download anything.
    ( $out, $err, $rc ) = run_bin( 'recipes', 'ufw' );
    ok( !exists Cpanel::JSON::XS->new->decode($out)->{'x-fetch-hosts'}, 'and a recipe that downloads nothing says nothing' );
};

subtest 'bin/recipes on a name that is not one' => sub {
    my ( undef, $err, $rc ) = run_bin( 'recipes', 'nosuchrecipe' );
    isnt( $rc, 0, 'fails' );
    like( $err, qr/No[ ]recipe[ ]named[ ]'nosuchrecipe'/, 'saying so' );
    like( $err, qr/bin\/recipes/,                         'and where to look' );
};

subtest 'bin/recipes --scaffold shows what new_guest would write' => sub {
    my ( $out, undef, $rc ) = run_bin(qw{recipes --scaffold mariadb});
    is( $rc, 0, 'exits clean' );

    my $got = eval { Cpanel::JSON::XS->new->decode($out) };
    is( $got->{configuration}{mariadb}{root_pw}, 'CHANGEME', 'the configuration' ) or diag $@;
    is_deeply( $got->{needs_filling}, [qw{mariadb.dumpfile mariadb.root_pw mariadb.version}], 'and the todo list' );
};

done_testing();
