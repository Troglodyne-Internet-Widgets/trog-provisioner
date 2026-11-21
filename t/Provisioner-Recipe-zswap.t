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
use Provisioner::Cookbook();

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

subtest 'enrich' => sub {
    my $protect = sub {
        my (%opts) = @_;
        my %out = 'Provisioner::Recipe::zswap'->new(%PROV)->validate(%opts);
        return $out{protect};
    };

    is_deeply( $protect->( modules => [] ),          ['dbus.service'],                      'a guest with no recipe that names a unit protects dbus alone' );
    is_deeply( $protect->( modules => ['nginx'] ),   ['dbus.service'],                      'and so does one whose recipes name none' );
    is_deeply( $protect->( modules => ['mariadb'] ), [ 'dbus.service', 'mariadb.service' ], 'mariadb protects its own unit, with nobody listing it' );

    # The recipes add to what the operator wrote, and do not replace it.
    is_deeply( $protect->( modules => ['mariadb'], protect => [ 'mariadb.service', 'bogus.service' ] ), [ 'bogus.service', 'mariadb.service' ], 'a unit that both name is said once, beside the units of the operator' );

    my $omit = sub {
        my (%opts) = @_;
        my %out = 'Provisioner::Recipe::zswap'->new(%PROV)->validate(%opts);
        return $out{oomd_omit};
    };

    is_deeply( $omit->( modules => [] ),                                       [],                                 'a guest with no recipe that names a unit omits none' );
    is_deeply( $omit->( modules => ['sshd'] ),                                 ['ssh.service'],                    'sshd has systemd-oomd skip its listener' );
    is_deeply( $omit->( modules => ['sshd'], oomd_omit => ['bogus.service'] ), [ 'bogus.service', 'ssh.service' ], 'beside the units of the operator' );

    # Both drop-ins have one path, so the unit gets one of them.  Protection
    # includes the omit, so it wins.
    is_deeply( $omit->( modules => ['sshd'], protect => ['ssh.service'] ), [], 'a unit that is protected is not in the list to omit as well' );
};

subtest 'oom_protect and oomd_omit of every recipe' => sub {

    # enrich runs after validation, so the schema never sees these names.  Each
    # one becomes a path under /etc/systemd/system.
    my $schema = { 'Provisioner::Recipe::zswap'->args() };
    my $unit   = $schema->{properties}{protect}{items}{pattern};
    is( $schema->{properties}{oomd_omit}{items}{pattern}, $unit, 'both lists take the same unit names' );
    my $count = 0;
    foreach my $name ( Provisioner::Cookbook->names() ) {
        my $recipe = Provisioner::Cookbook->load($name);
        foreach my $u ( $recipe->oom_protect(), $recipe->oomd_omit() ) {
            $count++;
            like( $u, qr/$unit/, "$name names a unit that the schema accepts: $u" );
        }
    }
    ok( $count, 'and at least one recipe names one' );
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
