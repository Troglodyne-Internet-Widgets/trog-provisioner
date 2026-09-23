#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/openstack-env.t - bin/openstack-env: what it hands the tools that read
clouds.yaml, and what it refuses to print

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture_stdout};

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Trog::OpenStack::Auth();                                                                         ## no critic (ProhibitUnusedImports) -- mocked below
use Trog::OpenStack::Config();                                                                       ## no critic (ProhibitUnusedImports) -- mocked below

my $script = "$FindBin::Bin/../bin/openstack-env";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

my %CLOUD = (
    name                          => 'openstack',
    source                        => '/bogus/clouds.yaml',
    auth_url                      => 'https://keystone.test.test:5000/v3',
    auth_type                     => 'v3applicationcredential',
    application_credential_id     => 'abc123',
    application_credential_secret => 'secret:openstack/credential/password',
    interface                     => 'public',
    identity_api_version          => 3,
    region_name                   => 'RegionOne',
);

# A run of main with the cloud and the secret it would have read, and stdout
# not a terminal, which is how it is used: eval "$(bin/openstack-env)".
sub run_with {
    my ( $cloud, $secret, @args ) = @_;

    my $config = Test::MockModule->new('Trog::OpenStack::Config');
    $config->redefine( load => sub { return {%$cloud} } );
    my $auth = Test::MockModule->new('Trog::OpenStack::Auth');
    $auth->redefine( secret_for => sub { return $secret } );
    my $bin = Test::MockModule->new( 'Trog::Bin::OpenStackEnv', no_auto => 1 );
    $bin->redefine( _is_terminal => sub { 0 } );

    my ( $out, $rc );
    $out = capture_stdout( sub { $rc = Trog::Bin::OpenStackEnv::main(@args) } );
    return ( $out, $rc );
}

subtest 'the environment the OpenStack tools read' => sub {
    my ( $out, $rc ) = run_with( \%CLOUD, sub { 'the-secret' } );

    is( $rc, 0, 'it finishes' );

    my %exported = $out =~ m/^export[ ](\w+)=(\N*)$/gm;
    is( $exported{OS_APPLICATION_CREDENTIAL_SECRET}, q{'the-secret'},                         'the credential, resolved out of the store' );
    is( $exported{OS_APPLICATION_CREDENTIAL_ID},     q{'abc123'},                             'the half of it that is not a secret' );
    is( $exported{OS_AUTH_URL},                      q{'https://keystone.test.test:5000/v3'}, 'where the cloud is' );
    is( $exported{OS_AUTH_TYPE},                     q{'v3applicationcredential'},            'how to authenticate to it' );
    is( $exported{OS_REGION_NAME},                   q{'RegionOne'},                          'the region' );
    is( $exported{OS_INTERFACE},                     q{'public'},                             'the interface' );
    is( $exported{OS_IDENTITY_API_VERSION},          q{'3'},                                  'and the identity version' );

    # Exporting it would send the client back to the file this works around,
    # where the credential is a reference it cannot read.
    ok( !exists $exported{OS_CLOUD}, 'OS_CLOUD is not exported' );
};

subtest 'a cloud that says less' => sub {
    my %thin = %CLOUD;
    delete @thin{qw{region_name interface}};
    $thin{identity_api_version} = undef;

    my ($out) = run_with( \%thin, 'written-out' );

    unlike( $out, qr/OS_REGION_NAME/,          'a value the cloud does not set is left out' );
    unlike( $out, qr/OS_IDENTITY_API_VERSION/, 'and so is one that is undef' );
    like( $out, qr/OS_APPLICATION_CREDENTIAL_SECRET='written-out'/, 'a secret written out in the file is handed over as it is' );
};

subtest 'a secret goes through a shell unhurt' => sub {
    my ($out) = run_with( \%CLOUD, sub { q{it's $HOME `uname` "quoted"} } );

    my ($line) = $out =~ m/^(export[ ]OS_APPLICATION_CREDENTIAL_SECRET=\N*)$/m;
    is( $line, q{export OS_APPLICATION_CREDENTIAL_SECRET='it'\\''s $HOME `uname` "quoted"'}, 'single quoted, with the quote inside it closed and reopened' );

    # What the shell makes of it is the thing that matters, so ask a shell.
    my $read_back = qx{$line; printf '%s' "\$OS_APPLICATION_CREDENTIAL_SECRET"};    ## no critic (logicLAB::ProhibitShellDispatch) -- the assertion is about what a shell does with the line
    is( $read_back, q{it's $HOME `uname` "quoted"}, 'and a shell reads back exactly the secret' );
};

subtest 'it refuses to print a secret to a terminal' => sub {
    my $config = Test::MockModule->new('Trog::OpenStack::Config');
    $config->redefine( load => sub { return {%CLOUD} } );
    my $auth = Test::MockModule->new('Trog::OpenStack::Auth');
    $auth->redefine( secret_for => sub { return 'the-secret' } );
    my $bin = Test::MockModule->new( 'Trog::Bin::OpenStackEnv', no_auto => 1 );
    $bin->redefine( _is_terminal => sub { 1 } );

    my $err = exception {
        capture_stdout( sub { Trog::Bin::OpenStackEnv::main() } )
    };
    like( $err, qr/refuses[ ]a[ ]terminal/, 'a terminal is refused, where it would sit in the scrollback' );
    like( $err, qr/eval/,                   'saying how it is meant to be run' );

    my ($out) = capture_stdout( sub { Trog::Bin::OpenStackEnv::main('--show') } );
    like( $out, qr/OS_APPLICATION_CREDENTIAL_SECRET='the-secret'/, 'and --show prints it anyway' );
};

subtest 'a cloud with no credential at all' => sub {
    my %none = ( %CLOUD, application_credential_secret => undef );

    my $err = exception { run_with( \%none, undef ) };
    like( $err, qr/no[ ]application[ ]credential[ ]secret/, 'is said, rather than exported empty' );
    like( $err, qr/bogus\/clouds\.yaml/,                    'naming the file it came from' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
