#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-openvpn.t - the CIDR blocks that the openvpn recipe takes

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

# A recipe per call: validated() is memoised on the object.
sub fresh {
    return Provisioner::Cookbook->load( 'openvpn', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

my %BASE = ( domain => 'vpn.test.test', admin_user => 'someadmin' );

subtest 'routes: a block must be an IPv4 address and a prefix of 0 to 32' => sub {
    foreach my $good (qw{192.0.2.0/24 192.0.2.7/32 0.0.0.0/0 192.0.2.5/24}) {
        is( exception { fresh()->validate( %BASE, routes => [$good] ) }, undef, "$good is taken" );
    }

    foreach my $bad (qw{999.0.2.0/24 192.0.2.0/99 192.0.2.0/33 1234.0.2.0/24 192.0.2.0}) {
        like( exception { fresh()->validate( %BASE, routes => [ '192.0.2.0/24', $bad ] ) }, qr/\Q$bad\E.*not[ ]an[ ]IPv4[ ]CIDR[ ]block|not[ ]valid/, "$bad is refused" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
