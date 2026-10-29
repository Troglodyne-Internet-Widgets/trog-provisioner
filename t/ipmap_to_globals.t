#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/ipmap_to_globals.t - the move from the older ipmap.cfg into recipes.yaml

=cut

use Test::More;
use Capture::Tiny qw{capture_stdout};
use Test::Fatal   qw{exception};
use File::Temp    qw{tempdir};

use FindBin;
use FindBin::libs;

## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether the move left a file where it says

use File::Slurper();
use File::Slurper::Temp();
use YAML::XS();

my $script = "$FindBin::Bin/../bin/ipmap_to_globals";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# An installation as it stood before the two files became one: the settings in
# ipmap.cfg, the recipes in recipes.yaml.
sub installation {
    my ($recipes) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/ipmap.cfg", <<'IPMAP' );
[global]
basedir=/opt/domains
admin_user=someadmin
admin_gecos=Some Admin
admin_email=someadmin@test.test
gateway=192.0.2.254
resolvers=192.0.2.254, 8.8.8.8
dhcp_devname=ens3
[ip_pool]
addresses=192.0.2.100 192.0.2.101
cidr=192.0.2.0/24
[nameservers]
ns1=ns1.test.test
[aliases]
one.test.test=solo.test.test
two.test.test=first.test.test, second.test.test
[ips]
one.test.test=192.0.2.100
IPMAP

    File::Slurper::Temp::write_binary( "$dir/recipes.yaml", YAML::XS::Dump( $recipes // { 'one.test.test' => { ntp => undef } } ) );

    return $dir;
}

sub moved {
    my ($dir) = @_;

    my $said = capture_stdout { Trog::Bin::IpmapToGlobals::main( '--ipmap', "$dir/ipmap.cfg", '--recipes', "$dir/recipes.yaml" ) };
    return ( YAML::XS::Load( File::Slurper::read_binary("$dir/recipes.yaml") ), $said );
}

subtest 'every block lands where the reader of it now looks' => sub {
    my ( $conf, $said ) = moved( installation() );
    my $global = $conf->{_base}{_global};

    is( $global->{basedir},     '/opt/domains',        'the globals become the _global of _base' );
    is( $global->{admin_email}, 'someadmin@test.test', 'key for key' );

    # The block of each hypervisor names its resolvers, its gateway and its
    # pool now.
    ok( !exists $global->{resolvers}, 'resolvers stay behind' );
    like( $said, qr/\[global\][ ]resolvers/, 'and the report names them' );
    ok( !exists $global->{gateway}, 'and so does the gateway' );
    like( $said, qr/\[global\][ ]gateway/, 'and the report names it' );
    ok( !exists $global->{ip_pool}, 'and so does the pool' );
    like( $said, qr/\[ip_pool\],[ ]which[ ]is[ ]pool_addresses[ ]and[ ]pool_cidr/, 'and the report says what it is now' );
    like( $said, qr/in[ ]the[ ]block[ ]of[ ]each[ ]hypervisor/,                    'and where' );

    ok( !exists $global->{nameservers}, 'the nameservers stay behind' );
    like( $said, qr/\[nameservers\],[ ]because/,           'and the report names them' );
    like( $said, qr/zone[ ]of[ ]a[ ]pdns[ ]guest[ ]names/, 'and says why' );

    # An alias belongs to the domain that answers to it, which is where
    # Provisioner::Cookbook/alias_map reads it from.
    is_deeply( $conf->{'one.test.test'}{_global}{aliases}, ['solo.test.test'],                        'a domain with one alias gets a list of one' );
    is_deeply( $conf->{'two.test.test'}{_global}{aliases}, [ 'first.test.test', 'second.test.test' ], 'and one with two keeps both' );

    ok( !exists $global->{ips}, 'the addresses are not moved, ips.db having owned them for years' );

    # globals refuses a key that nothing declares, so moving one would write a
    # configuration that the next command refuses.
    ok( !exists $global->{dhcp_devname}, 'a setting that nothing reads stays behind' );
    my ( undef, $left_out ) = split( /does[ ]not[ ]take[ ]it:/, $said, 2 );
    like( $left_out // q{}, qr/\[global\][ ]dhcp_devname/, 'and the report names it' );
    like( $said,            qr/\[global\][ ]basedir/,      'the report says what moved' );
};

subtest 'what recipes.yaml already says is left alone, and said so' => sub {
    my $dir = installation(
        {
            _base           => { _global => { admin_user => 'somebody', admin_email => 'kept@test.test' } },
            'one.test.test' => { _global => { aliases    => ['kept.test.test'] }, ntp => undef },
        }
    );

    my ( $conf, $said ) = moved($dir);

    is( $conf->{_base}{_global}{admin_user},  'somebody',       'a setting already written is not overwritten' );
    is( $conf->{_base}{_global}{admin_email}, 'kept@test.test', 'nor another one' );
    is_deeply( $conf->{'one.test.test'}{_global}{aliases}, ['kept.test.test'], 'nor the aliases of a domain' );
    is( $conf->{_base}{_global}{basedir}, '/opt/domains', 'while the rest still moves across' );

    like( $said, qr/_base\._global\.admin_user/, 'and the report names what it left' );
};

subtest 'the old file is kept, and the old recipes.yaml backed up' => sub {
    my $dir = installation();
    moved($dir);

    ok( -f "$dir/ipmap.cfg",        'ipmap.cfg is still there, this not being the moment to delete somebody configuration' );
    ok( -f "$dir/recipes.yaml.bak", 'and the recipes.yaml it replaced is beside the new one' );
};

subtest 'a dry run writes nothing' => sub {
    my $dir    = installation();
    my $before = File::Slurper::read_binary("$dir/recipes.yaml");

    my $said = capture_stdout { Trog::Bin::IpmapToGlobals::main( '--ipmap', "$dir/ipmap.cfg", '--recipes', "$dir/recipes.yaml", '--dryrun' ) };

    is( File::Slurper::read_binary("$dir/recipes.yaml"), $before, 'the file is as it was' );
    ok( !-f "$dir/recipes.yaml.bak", 'and no backup was taken, there being nothing to back up' );
    like( $said, qr/nothing[ ]was[ ]written/, 'while the report says what it would have done' );
};

subtest 'an installation with no ipmap.cfg is told there is nothing to do' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $err = exception { Trog::Bin::IpmapToGlobals::main( '--ipmap', "$dir/ipmap.cfg", '--recipes', "$dir/recipes.yaml" ) };

    like( $err, qr/nothing[ ]to[ ]do/, 'rather than an empty _global written over the configuration' );
};

done_testing();
