#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

# The generator is loaded when the test runs rather than when it compiles, so
# perl sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/new_config-hypervisor.t - what bin/new_config asks Trog::Hypervisors->choose
for, from the command line and from the configuration

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: what this asserts should not
# depend on which machine it runs on.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempfile};
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAdogeskey doge\n" );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my ( $ih, $IPMAP ) = tempfile();
print {$ih} <<'IPMAP';
[global]
basedir=/bogus/domains
transfer_user=doge
admin_user=doge
admin_email=bogus@test.test
admin_gecos=Test Test
gateway=192.168.1.254
resolvers=192.168.1.254
IPMAP
close($ih) or die "Could not close $IPMAP: $!";

my $RECIPES = "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml";
File::Slurper::Temp::write_text(
    $RECIPES,
    YAML::XS::Dump(
        {
            _base              => { _global          => { memory => 2048 } },
            _shared            => { 'host.test.test' => ['tenant.test.test'] },
            'vm.test.test'     => { _global => { cpus => 2 }, ntp => undef },
            'host.test.test'   => { _global => { cpus => 8 }, ntp => undef },
            'tenant.test.test' => { ntp => undef },
        }
    )
);

# Runs $code, which runs the generator, as far as the choice of hypervisor, and
# returns what each call to choose was given, keyed by domain.
sub choices {
    my ($code) = @_;

    my %asked;
    my $mock = Test::MockModule->new('Trog::Hypervisors');
    $mock->redefine(
        choose => sub {
            my ( undef, $domain, %opts ) = @_;
            $asked{$domain} = \%opts;
            die "far enough\n";
        }
    );

    Provisioner::Cookbook->forget();
    like( exception { $code->() }, qr/\Afar[ ]enough$/m, 'got as far as the choice' );
    return \%asked;
}

sub main_with {
    my (@args) = @_;
    return sub { Trog::Provisioner::Config::Generator::main( '--ipmap', $IPMAP, '--recipes', $RECIPES, '--skip_ssh', @args ) };
}

subtest 'the command line reaches the choice' => sub {
    my $asked = choices( main_with( qw{--hvconf /bogus/fleet.conf --connect qemu+ssh://root@hv.test.test/system --domaindir /bogus/elsewhere}, 'vm.test.test' ) );
    my $vm    = $asked->{'vm.test.test'};

    is( $vm->{hvconf},         '/bogus/fleet.conf',                   '--hvconf' );
    is( $vm->{uri},            'qemu+ssh://root@hv.test.test/system', '--connect' );
    is( $vm->{domain_dir},     '/bogus/elsewhere',                    '--domaindir' );
    is( $vm->{config}{cpus},   2,                                     'and the _global of the domain' );
    is( $vm->{config}{memory}, 2048,                                  'with what _base gives it' );
    ok( !defined $vm->{host}, 'a domain with its own machine names no host' );

    # main runs once for each call in bin/provision, and a later call must not
    # keep the options of an earlier one.
    $vm = choices( main_with('vm.test.test') )->{'vm.test.test'};
    ok( !defined $vm->{$_}, "and a second run without it does not keep $_" ) for qw{hvconf uri domain_dir};
};

subtest 'a tenant is chosen for by its host' => sub {

    # main generates the host first, so the choice is made for the host first.
    my $asked = choices( main_with('tenant.test.test') );
    is_deeply( [ keys %$asked ], ['host.test.test'], 'main asks about the host first' );

    # The tenant itself, as main reaches it once the host is generated.
    local $Trog::Provisioner::Config::Generator::cfile    = $IPMAP;
    local $Trog::Provisioner::Config::Generator::pfile    = $RECIPES;
    local $Trog::Provisioner::Config::Generator::skip_ssh = 1;
    my $tenant = choices( sub { Trog::Provisioner::Config::Generator::handle_domain('tenant.test.test') } )->{'tenant.test.test'};

    is( $tenant->{host},                'host.test.test', 'the tenant names its host' );
    is( $tenant->{host_config}{cpus},   8,                'and passes the _global of the host' );
    is( $tenant->{host_config}{memory}, 2048,             'with what _base gives it' );
    is( $tenant->{config}{memory},      2048,             'beside its own configuration' );
};

done_testing();
