#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/prose_check.t - bin/prose_check refuses prose that names the fleet, and
never says the name

=head1 DESCRIPTION

The configuration and the fleet here hold made-up names.  The check runs in a
repository of its own, whose tracked file makes F<test.test> and C<root>
public.

=cut

use FindBin;
use FindBin::libs;

# Never the real configuration of the installation.
## no critic (CompileTime) -- setting it at compile time is the point.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Test::More;
use IPC::Run3();
use File::Slurper::Temp();
use YAML::XS();

my $script = "$FindBin::Bin/../bin/prose_check";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

File::Slurper::Temp::write_text(
    "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml",
    YAML::XS::Dump(
        {
            _base => {
                _global => {
                    basedir     => '/bogus',
                    admin_user  => 'hiddenadmin',
                    admin_gecos => 'Ophelia Quuxworth',
                    admin_email => 'hiddenadmin@mail.quuxcorp.test.test',
                    user        => 'root',
                },
            },
            'shop.quuxcorp.test.test' => {
                _global => { aliases => ['store.quuxcorp.test.test'], user => 'shopsvc' },
                git     => { forge   => 'forge.othercorp.test.test' },
            },
        }
    )
);
File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/hypervisors.conf", <<'INI' );
[bogushv]
libvirt_uri = qemu+ssh://root@hv1.quuxdc.test.test/system
ip_pool_br0 = 192.0.2.64/26
gateway_br0 = 192.0.2.1
INI

# Not this checkout, which tracks this file and so every name in it.  A
# repository of its own, whose one tracked file makes two names public.
my $repo = File::Temp::tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$repo/README", "Guests are test.test names, and files belong to root.\n" );
IPC::Run3::run3( [ qw{git -C}, $repo, @$_ ], \undef, \my $out, \my $err ) for [qw{init -q}], [qw{add README}];
chdir($repo) or die "Cannot change to $repo: $!\n";

my sub check ($prose) {
    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run3::run3( [ $^X, $script ], \$prose, \$out, \$err );
    return ( $? >> 8, $out . $err );
}

my %refused = (
    'a domain of the configuration'               => [ 'it runs on shop.quuxcorp.test.test', 'and on Store.QuuxCorp.test.test too' ],
    'the parent of a domain of the configuration' => ['the zone quuxcorp.test.test'],
    'an account of the configuration'             => [ 'ssh as hiddenadmin', 'chown shopsvc' ],
    'the name of a person'                        => ['ask Ophelia Quuxworth'],
    'a mail address that the configuration names' => ['mail hiddenadmin@mail.quuxcorp.test.test'],
    'a host that the configuration names'         => [ 'clone from forge.othercorp.test.test', 'on hv1.quuxdc.test.test' ],
    'a hypervisor of the fleet'                   => ['built on bogushv'],
    'an address that the configuration names'     => ['the gateway 192.0.2.1'],
    'an address of the fleet'                     => ['the guest at 192.0.2.70'],
);

foreach my $kind ( sort keys %refused ) {
    foreach my $prose ( @{ $refused{$kind} } ) {
        my ( $exit, $said ) = check("a first line\n$prose\n");
        is( $exit, 1, "refused: $prose" );
        like( $said, qr/^line\ 2:\ \Q$kind\E$/m, "and it names the line and the kind: $kind" );
    }
}

foreach my $prose (
    'the domain $domain on $hv',
    'a zone such as test.test',
    'files go to root',
    'hiddenadminx and xhiddenadmin are other words',
    'a.shop.quuxcorp.test.test.evil is another name',
    'the guest at 192.0.2.128',
    'version 192.0.2.70.1 is not an address',
) {
    my ( $exit, $said ) = check("$prose\n");
    is_deeply( [ $exit, $said ], [ 0, q{} ], "allowed: $prose" );
}

my ( undef, $said ) = check("shop.quuxcorp.test.test and hiddenadmin, at 192.0.2.70\nfine\nbogushv\n");
is( $said, "line 1: a domain of the configuration\nline 1: an account of the configuration\nline 1: an address of the fleet\nline 3: a hypervisor of the fleet\n", 'one line for each line and kind, in order' );
unlike( $said, qr/quuxcorp|hiddenadmin|192\.0\.2\.70|bogushv/i, 'and the output holds none of the names' );

done_testing();
