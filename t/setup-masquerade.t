#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/setup-masquerade.t - scripts/setup-masquerade: the two rules a VPN needs, and not a second copy of either

=cut

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp       qw{tempdir};
use File::Slurper    qw{read_text};
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/setup-masquerade";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# What ufw ships, trimmed to the lines that matter here: the required chain
# declarations, one rule of ufw's own in each direction, and the COMMIT that
# closes the only table in the file.  There is no *nat table, which is the whole
# reason this script has to make one.
my $SHIPPED = <<'RULES';
#
# rules.before
#

# Don't delete these required lines, otherwise there will be errors
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]
# End required lines

# allow all on loopback
-A ufw-before-input -i lo -j ACCEPT

# quickly process packets for which we already have a connection
-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# don't delete the 'COMMIT' line or these rules won't be processed
COMMIT
RULES

# Every run in here is against a file in a temporary directory, and neither the
# firewall nor the routing table of whatever is running this is asked anything.
my $reloads = 0;
my $mock    = Test::MockModule->new( 'Trog::Script::SetupMasquerade', no_auto => 1 );
$mock->redefine( _reload         => sub { $reloads++; return } );
$mock->redefine( _default_routes => sub { return "default via 192.168.1.254 dev ens4 proto static\n" } );

sub rules_file {
    my ($content) = @_;
    my $dir       = tempdir( CLEANUP => 1 );
    my $path      = "$dir/before.rules";
    File::Slurper::Temp::write_text( $path, $content // $SHIPPED );
    return $path;
}

sub run_on {
    my ( $path, @args ) = @_;

    # The script is required at run time, so at this file's compile time nothing
    # has declared $FILE and naming it here is a "used only once" warning -- and
    # warnings are fatal in this file.
    no warnings 'once';    ## no critic (ProhibitNoWarnings)
    local $Trog::Script::SetupMasquerade::FILE = $path;
    open( my $capture, '>', \my $said ) or die $!;
    my $rc = do { local *STDOUT = $capture; Trog::Script::SetupMasquerade::main(@args) };
    close $capture;
    return ( $rc, read_text($path), $said // q{} );
}

subtest 'a VPN subnet gets forwarded and masqueraded, in one nat table' => sub {
    my $path = rules_file();
    my ( $rc, $after ) = run_on( $path, '10.8.0.0/24=eth0' );

    is( $rc, 0, 'it succeeds' );

    like( $after, qr{^-A trog-nat -s 10[.]8[.]0[.]0/24 -o eth0 -j MASQUERADE$}m, 'the subnet is masqueraded out of the named interface' );
    like( $after, qr{^-A ufw-before-forward -s 10[.]8[.]0[.]0/24 -j ACCEPT$}m,   'and forwarded, which is what makes the masquerade reachable' );

    # In a chain of our own, reached by one jump.  ufw reloads with
    # iptables-restore --noflush, which flushes a user chain the input declares
    # and never flushes a built-in one -- so a MASQUERADE written straight into
    # POSTROUTING gained a duplicate on every reload and this cannot.
    like( $after, qr{^:trog-nat - \[0:0\]$}m,        'the chain is declared' );
    like( $after, qr{^-A POSTROUTING -j trog-nat$}m, 'and POSTROUTING jumps to it' );

    # Declared before it is used, or iptables-restore refuses the file and ufw
    # does not start.
    ok( index( $after, ':trog-nat' ) < index( $after, '-A POSTROUTING -j trog-nat' ), 'declared above the jump' );

    my $decls = () = $after =~ m/^:trog-nat /mg;
    is( $decls, 1, 'and declared once, since twice is a file iptables-restore refuses' );
    like(
        $after, qr{^-A ufw-before-forward -d 10[.]8[.]0[.]0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT$}m,
        'and the answers get back to it'
    );

    # A table declared twice is a file iptables-restore refuses outright, which
    # is ufw failing to start rather than one rule going missing.
    my $nats = () = $after =~ m/^[*]nat\b/mg;
    is( $nats, 1, 'exactly one nat table' );
    my $filters = () = $after =~ m/^[*]filter\b/mg;
    is( $filters, 1, 'and exactly one filter table' );

    # Ahead of *filter, which is where a nat table has to be.
    ok( index( $after, '*nat' ) < index( $after, '*filter' ), 'the nat table comes first' );

    # At the end of the filter table, so ufw's own loopback and conntrack rules
    # are read before ours.
    ok(
        index( $after, '-A ufw-before-forward -m conntrack' ) < index( $after, '-A ufw-before-forward -s 10.8.0.0/24' ),
        'and our accepts are read after the ones ufw ships'
    );
};

subtest 'running it again changes nothing, and reloads nothing' => sub {
    my $path = rules_file();
    my ( undef, $first, $said ) = run_on( $path, '10.8.0.0/24=eth0' );
    like( $said, qr/^Wrote 1 masquerade and 2 forwarding rule/, 'the first run says what it wrote' );

    $reloads = 0;
    my ( $rc, $second, $quiet ) = run_on( $path, '10.8.0.0/24=eth0' );
    is( $rc,      0,      'the second run succeeds' );
    is( $second,  $first, 'and leaves the file byte for byte as it was' );
    is( $quiet,   q{},    'saying nothing, because it did nothing' );
    is( $reloads, 0,      'and not reloading a firewall that has not changed' );
};

subtest 'a subnet that changed does not leave the old one behind' => sub {
    my $path = rules_file();
    run_on( $path, '10.8.0.0/24=eth0' );
    my ( undef, $after ) = run_on( $path, '10.9.0.0/24=eth0' );

    unlike( $after, qr/10[.]8[.]0[.]0/, 'nothing of the old subnet is left' );
    like( $after, qr{^-A trog-nat -s 10[.]9[.]0[.]0/24 -o eth0 -j MASQUERADE$}m, 'and the new one is masqueraded' );
    like( $after, qr{^-A ufw-before-forward -s 10[.]9[.]0[.]0/24 -j ACCEPT$}m,   'and forwarded' );

    my $nats = () = $after =~ m/^[*]nat\b/mg;
    is( $nats, 1, 'still one nat table' );

    my $decls = () = $after =~ m/^:trog-nat /mg;
    is( $decls, 1, 'and still one chain declaration' );

    my $jumps = () = $after =~ m/^-A POSTROUTING -j trog-nat$/mg;
    is( $jumps, 1, 'and one jump into it' );
};

subtest 'a rule written before there were markers is swept up, and a stranger is not' => sub {

    # What a guest provisioned by the older version of this script has in its
    # file: our MASQUERADE rule with nothing around it to find it by.  Left
    # alone it sits beside the marked copy for the life of the guest.
    my $legacy = $SHIPPED;
    $legacy =~ s{^([*]filter\b)}{*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.8.0.0/24 -o enp1s0 -j MASQUERADE\n-A POSTROUTING -s 172.16.0.0/12 -o eth9 -j MASQUERADE\nCOMMIT\n\n$1}m;

    my $path = rules_file($legacy);
    my ( undef, $after ) = run_on( $path, '10.8.0.0/24=eth0' );

    my $ours = () = $after =~ m{^-A \S+ -s 10[.]8[.]0[.]0/24 .*MASQUERADE$}mg;
    is( $ours, 1, 'one rule for the subnet, not the old one and the new one' );
    like( $after, qr{^-A trog-nat -s 10[.]8[.]0[.]0/24 -o eth0 -j MASQUERADE$}m, 'and it is the one this run wrote, in the chain' );

    # The old shape went straight into POSTROUTING, so a guest provisioned
    # before this has one to be swept rather than only a marked block to drop.
    unlike( $after, qr{^-A POSTROUTING -s 10[.]8[.]0[.]0/24 }m, 'the POSTROUTING copy an older version wrote is gone' );

    like(
        $after, qr{^-A POSTROUTING -s 172[.]16[.]0[.]0/12 -o eth9 -j MASQUERADE$}m,
        'a masquerade for something else is somebody elses and is left alone'
    );
};

subtest 'the interface is asked of the guest when the domain does not name one' => sub {
    my $path = rules_file();
    my ( undef, $after ) = run_on( $path, '10.8.0.0/24' );

    like(
        $after, qr{^-A trog-nat -s 10[.]8[.]0[.]0/24 -o ens4 -j MASQUERADE$}m,
        'it masquerades out of the interface the default route leaves by'
    );
};

subtest 'and a guest with no default route is told to name one rather than left silent' => sub {
    my $quiet = Test::MockModule->new( 'Trog::Script::SetupMasquerade', no_auto => 1 );
    $quiet->redefine( _default_routes => sub { return q{} } );

    my $path = rules_file();
    like(
        exception { run_on( $path, '10.8.0.0/24' ) },
        qr/no default route/,
        'which is an error, because a rule left out here looks exactly like a working VPN'
    );
};

subtest 'no subnets is a no-op rather than an empty block' => sub {
    my $path = rules_file();
    my ( $rc, $after ) = run_on($path);

    is( $rc,    0,        'it succeeds' );
    is( $after, $SHIPPED, 'and leaves the file exactly as ufw shipped it' );
};

done_testing();
