#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-zswap.t - a tenant with the settings of its host is not
refused, and a swap size that make_swapfile cannot read is

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};

use FindBin::libs;

use_ok('Provisioner::Recipe::zswap') or BAIL_OUT('Provisioner::Recipe::zswap does not load');

my %PROV = ( output_dir => '/bogus', libdir => '.', target_packager => 'deb' );

subtest 'machine_wide' => sub {
    my $recipe = 'Provisioner::Recipe::zswap'->new(%PROV);

    # bin/new_config compares each setting with ne.  A list that came back as a
    # reference would differ from every other list, the same one included.
    my %host   = $recipe->machine_wide( protect => [ 'dbus.service', 'ssh.service' ] );
    my %tenant = $recipe->machine_wide( protect => [ 'ssh.service',  'dbus.service' ] );
    is( $host{protect}, $tenant{protect},           'the same units in another order are the same setting' );
    is( $host{protect}, 'dbus.service,ssh.service', 'and each list comes back as one string' ) or diag explain \%host;

    my %default = $recipe->machine_wide();
    is( $default{kill_on_pressure}, 'system.slice,user.slice', 'a setting left out is the default of the schema' );
    isnt( $default{protect}, $host{protect}, 'and another list of units is another setting' );
};

subtest 'swap_size' => sub {
    my $size = sub {
        my ($value) = @_;
        my %opts = 'Provisioner::Recipe::zswap'->new(%PROV)->validate( swap_size => $value );
        return $opts{swap_size};
    };

    is( $size->($_), $_, "$_ is a size that make_swapfile reads" ) for qw{50% 100% 2G 512M 1048576};

    # numfmt --from=iec refuses a suffix in lower case, so the schema refuses it
    # before a guest is built.
    foreach my $bad (qw{2g 0 05G 2GB -1G 50%%}) {
        ok( exception { $size->($bad) }, "$bad is refused" );
    }
};

subtest 'protect' => sub {

    # Each name becomes a path under /etc/systemd/system.
    my $err = exception { 'Provisioner::Recipe::zswap'->new(%PROV)->validate( protect => ['../../bogus.service'] ) };
    ok( $err, 'a unit name that climbs out of /etc/systemd/system is refused' );

    $err = exception { 'Provisioner::Recipe::zswap'->new(%PROV)->validate( protect => ['dbus'] ) };
    ok( $err, 'and so is one with no type, which systemd would not find' );
};

had_no_warnings();
done_testing();
