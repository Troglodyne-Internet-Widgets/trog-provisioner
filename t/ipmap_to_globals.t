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

    # Config::Simple writes a list as one comma-separated string, and every
    # reader of resolvers wants a list.
    is_deeply( $global->{resolvers}, [ '192.0.2.254', '8.8.8.8' ], 'resolvers become the list they are read as' );

    is_deeply( $global->{ip_pool},     { addresses => [ '192.0.2.100', '192.0.2.101' ], cidr => '192.0.2.0/24' }, 'the pool becomes one key' );
    is_deeply( $global->{nameservers}, { ns1       => 'ns1.test.test' },                                          'and the nameservers another' );

    # An alias belongs to the domain that answers to it, which is where
    # Provisioner::Cookbook/alias_map reads it from.
    is_deeply( $conf->{'one.test.test'}{_global}{aliases}, ['solo.test.test'],                        'a domain with one alias gets a list of one' );
    is_deeply( $conf->{'two.test.test'}{_global}{aliases}, [ 'first.test.test', 'second.test.test' ], 'and one with two keeps both' );

    ok( !exists $global->{ips}, 'the addresses are not moved, ips.db having owned them for years' );
    like( $said, qr/\[global\][ ]basedir/, 'the report says what moved' );
};

subtest 'what recipes.yaml already says is left alone, and said so' => sub {
    my $dir = installation(
        {
            _base           => { _global => { admin_user => 'somebody', resolvers => ['1.1.1.1'] } },
            'one.test.test' => { _global => { aliases    => ['kept.test.test'] }, ntp => undef },
        }
    );

    my ( $conf, $said ) = moved($dir);

    is( $conf->{_base}{_global}{admin_user}, 'somebody', 'a setting already written is not overwritten' );
    is_deeply( $conf->{_base}{_global}{resolvers},         ['1.1.1.1'],        'nor one already written as a list' );
    is_deeply( $conf->{'one.test.test'}{_global}{aliases}, ['kept.test.test'], 'nor the aliases of a domain' );
    is( $conf->{_base}{_global}{gateway}, '192.0.2.254', 'while the rest still moves across' );

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
