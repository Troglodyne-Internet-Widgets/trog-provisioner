#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-vendor.t - a recipe that lives in a vendor libdir is built like one
in this checkout

=cut

# Asserting a file was generated is what this file does, and -f is how you ask.
## no critic (ValuesAndExpressions::ProhibitFiletest_f)

use FindBin;
use FindBin::libs;

# Never the installation's real configuration, for the reasons
# t/new_config-shared.t gives.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- the whole file reads it after BEGIN returns, which local would undo

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Path       qw{make_path};
use File::Temp       qw{tempdir tempfile};
use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

use Provisioner::Cookbook();

File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/admin_authorized_keys", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAadminskey someadmin\n" );

require Trog::HV;
require Trog::HV::Libvirt;

# The two facts the generator asks a hypervisor for, as t/new_config-shared.t
# answers them.
my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
$hv_mock->redefine( virbr_ip  => sub { '192.168.122.1' } );
$hv_mock->redefine( sshd_port => sub { 22 } );

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

# A vendor libdir laid out as this checkout is: a recipe, its version for one
# distribution, and a template.  vendor_global is a _global setting that only
# this recipe declares.
my $VENDOR = tempdir( CLEANUP => 1 );
make_path( "$VENDOR/lib/Provisioner/Recipe/Ubuntu", "$VENDOR/templates" );

File::Slurper::Temp::write_text( "$VENDOR/lib/Provisioner/Recipe/vendorthing.pm", <<'PM' );
package Provisioner::Recipe::vendorthing;

#ABSTRACT: A recipe that is not in this checkout.

use 5.041;
use strict;
use warnings;
use parent qw{Provisioner::Recipe};

sub args {
    return (
        type       => 'object',
        properties => {
            vendor_setting => { type => 'string', default => 'unset' },
            vendor_global  => { type => 'string', default => 'unset' },
        },
    );
}

1;
PM

File::Slurper::Temp::write_text( "$VENDOR/lib/Provisioner/Recipe/Ubuntu/vendorthing.pm", <<'PM' );
package Provisioner::Recipe::Ubuntu::vendorthing;

use 5.041;
use strict;
use warnings;
use parent qw{Provisioner::Recipe::vendorthing};

sub deps { return qw{vendor-package} }

1;
PM

File::Slurper::Temp::write_text( "$VENDOR/templates/vendorthing.tt", "echo 'vendor: [% vendor_setting %] [% vendor_global %]'\n" );

my $DOMAIN = 'vendor.test.test';

# One domain that runs the vendor recipe, generated as bin/provision generates
# one.
sub generate {
    my (%global_extra) = @_;

    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/domains";
    mkdir "$tmpdir/data";
    mkdir "$tmpdir/data/$DOMAIN";

    my %recipes = (
        _base => {
            _global => {
                data_source   => "$tmpdir/data",
                basedir       => "$tmpdir/domains",
                transfer_user => 'someadmin',
                admin_user    => 'someadmin',
                admin_email   => 'bogus@test.test',
                admin_gecos   => 'Test Test',
                gateway       => '192.0.2.254',
                resolvers     => ['192.0.2.254'],
                ip_pool       => { addresses => '192.0.2.100' },
                nameservers   => { ns1       => 'ns1.test.test' },
                libdir        => [$VENDOR],
                %global_extra,
            },
        },
        $DOMAIN => { vendorthing => { vendor_setting => 'from-the-domain' } },
    );

    my ( $rh, $recipe_file ) = tempfile();
    print {$rh} YAML::XS::Dump( \%recipes );
    close($rh) or die "Could not close $recipe_file: $!";

    my $err = exception {
        Trog::Provisioner::Config::Generator::main( '--recipes', $recipe_file, '--skip_ssh', $DOMAIN );
    };

    return ( $err, "$tmpdir/domains/$DOMAIN" );
}

subtest 'the cookbook finds a vendor recipe once a configuration names its libdir' => sub {
    ok( !Provisioner::Cookbook->has('vendorthing'), 'before any configuration names the libdir, there is no such recipe' );

    Provisioner::Cookbook->configuration( write_config( { _base => { _global => { libdir => [$VENDOR] } } } ) );

    ok( Provisioner::Cookbook->has('vendorthing'),                     'after, there is' );
    ok( ( grep { $_ eq 'vendorthing' } Provisioner::Cookbook->names ), 'names lists it' );
    ok( ( grep { $_ eq 'nosnap' } Provisioner::Cookbook->names ),      'beside the recipes of this checkout' );
    is( Provisioner::Cookbook->abstract('vendorthing'),                   'A recipe that is not in this checkout.',   'abstract reads its file' );
    is( Provisioner::Cookbook->load('vendorthing'),                       'Provisioner::Recipe::vendorthing',         'load loads it' );
    is( Provisioner::Cookbook->load( 'vendorthing', distro => 'ubuntu' ), 'Provisioner::Recipe::Ubuntu::vendorthing', 'and its version for a distribution, from the same libdir' );

    my %declared = map { $_ => 1 } Provisioner::Cookbook->declared_globals;
    ok( $declared{vendor_global}, 'a _global setting only it declares is allowed' );

    is_deeply( [ Provisioner::Cookbook->use_libdirs($VENDOR) ], [$VENDOR], 'and naming the libdir again adds nothing' );

    my $other = tempdir( CLEANUP => 1 );
    is_deeply( [ Provisioner::Cookbook->use_libdirs( $other, $other ) ], [ $VENDOR, $other ], 'nor does naming one twice in the same call' );
};

subtest 'a domain that runs a vendor recipe generates' => sub {
    my ( $err, $dir ) = generate( vendor_global => 'from-the-installation' );

    is( $err, undef, 'the generation runs to the end' ) or diag $err;
    ok( -f "$dir/Makefile", 'and writes a Makefile' )   or return;

    my $makefile = File::Slurper::read_text("$dir/Makefile");
    like( $makefile, qr/vendor:[ ]from-the-domain[ ]from-the-installation/, 'with the fragment of the vendor recipe, rendered from its own template' );
};

subtest 'a readOnly field in _global is refused' => sub {

    # vm puts the MAC it derives into the domain XML, and the network
    # configuration matches on the MAC ubuntu is handed.  A _global value
    # would reach only the second.
    my ( $err, undef ) = generate( nat_mac => '52:54:00:00:00:01' );
    like( $err, qr{/nat_mac:[ ]The[ ]build[ ]works[ ]this[ ]out}, 'naming it, and saying why' );
};

sub write_config {
    my ($conf) = @_;
    my ( $fh, $file ) = tempfile();
    print {$fh} YAML::XS::Dump($conf);
    close($fh) or die "Could not close $file: $!";
    return $file;
}

done_testing();
