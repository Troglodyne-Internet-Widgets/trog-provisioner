#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/edge_manifest.t - bin/edge_manifest: which guests it lists, and what it says
about each

=cut

use FindBin;
use FindBin::libs;

# Never the installation's real configuration: this reads recipes.yaml, and the
# address database beside it.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use Test::MockModule qw{strict};
use Capture::Tiny    qw{capture};
use File::Path       qw{make_path};
use File::Slurper::Temp();
use Cpanel::JSON::XS();
use YAML::XS();

use Provisioner::Cookbook();

my $script = "$FindBin::Bin/../bin/edge_manifest";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

my %GLOBAL = (
    basedir     => '/bogus',
    admin_user  => 'someadmin',
    admin_gecos => 'Some Admin',
    admin_email => 'someadmin@test.test',
    gateway     => '192.0.2.254',
    resolvers   => ['192.0.2.254'],
    ip_pool     => { addresses => '192.0.2.10 192.0.2.11 192.0.2.12' },
);

File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    YAML::XS::Dump(
        {
            _base   => { _global         => \%GLOBAL },
            _shared => { 'web.test.test' => ['shop.test.test'] },

            # A public name in its own zone, and one outside every zone.
            'web.test.test' => { nginx => { public_names => { 'www2.web.test.test' => 'web.test.test', 'x.outside.test' => 'web.test.test' } }, mail => {} },

            # Layered onto web.test.test, so its names are that guest's.
            'shop.test.test' => { nginx => { public_names => { 'shop.customer.test' => 'shop.test.test' } }, mail => {} },

            'plain.test.test'  => { nginx => {} },
            'nokey.test.test'  => { nginx => { public_names => { 'nokey.test.test'  => 'nokey.test.test' } } },
            'noaddr.test.test' => { nginx => { public_names => { 'noaddr.test.test' => 'noaddr.test.test' } } },
        }
    )
);
Provisioner::Cookbook->forget();

my $pool = Test::MockModule->new('Provisioner::IPPool');
$pool->redefine( assignments => sub { return { 'web.test.test' => '192.0.2.10', 'plain.test.test' => '192.0.2.11', 'nokey.test.test' => '192.0.2.12' } } );

my $domains = File::Temp::tempdir( CLEANUP => 1 );
my $hv      = Test::MockModule->new('Trog::HV');
$hv->redefine( domain_dir => sub { return $domains } );
make_path("$domains/web.test.test");
File::Slurper::Temp::write_text( "$domains/web.test.test/key.rsa.pub", "ssh-rsa AAAAbogus web.test.test\n" );

my ( $out, $err, $rc ) = capture { Provisioner::Bin::edge_manifest::main() };
is( $rc, 0, 'it exits 0' ) or diag $err;
my $manifest = Cpanel::JSON::XS::decode_json($out);

is_deeply( [ sort keys %$manifest ], [qw{nokey.test.test web.test.test}], 'it lists each guest with a public name and an address, and no other' );
like( $err, qr/noaddr[.]test[.]test[ ]has[ ]public[ ]names/, 'and says which guest it left out for want of an address' );

my $web = $manifest->{'web.test.test'};
is( $web->{address}, '192.0.2.10', 'a guest has its address' );
is_deeply(
    $web->{names},
    [qw{public.shop.test.test public.web.test.test shop.customer.test www2.web.test.test x.outside.test}],
    'and the names of each domain on it: a public name, and public.VHOST beside a name outside every zone'
);
is_deeply( $web->{ports},        { 443 => 8443, 80 => 8080 },        'and the port of the guest for each port of the proxy' );
is_deeply( $web->{mail_domains}, [qw{shop.test.test web.test.test}], 'and each domain on it with mail' );
is( $web->{key}, 'ssh-rsa AAAAbogus web.test.test', 'and its public key' );

is( $manifest->{'nokey.test.test'}{key}, undef, 'a guest that has no key yet has a null key' );
is_deeply( $manifest->{'nokey.test.test'}{mail_domains}, [], 'and a guest with no mail has none' );

done_testing;
