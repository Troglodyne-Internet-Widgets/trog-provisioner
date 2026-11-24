#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/setup-ufw-metadata.t - scripts/setup-ufw-metadata: only root reaches the
metadata service, over each IP version, however often it runs

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/setup-ufw-metadata";

# The shape of the before.rules and before6.rules that ufw packages: a filter
# table that declares the chain, accepts loopback and established traffic in
# it, and ends in COMMIT.  A nat table before it, as setup-port-forwards
# writes one, has a COMMIT of its own that the block must not go in front of.
my %packaged = (
    'before.rules' => <<'RULES',
*nat
:POSTROUTING ACCEPT [0:0]
COMMIT
*filter
:ufw-before-output - [0:0]
-A ufw-before-output -o lo -j ACCEPT
-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
RULES
    'before6.rules' => <<'RULES',
*filter
:ufw6-before-output - [0:0]
-A ufw6-before-output -o lo -j ACCEPT
-A ufw6-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
RULES
);

my $dir = tempdir( CLEANUP => 1 );
for my $key ( keys %packaged ) { File::Slurper::Temp::write_text( "$dir/$key", $packaged{$key} ); }

# Runs the script on the rules in $dir, and returns them.
sub run_on {
    my (@addresses) = @_;
    local $ENV{UFW_RULES_DIR} = $dir;
    IPC::Run3::run3( [ $script, @addresses ], \undef, \my $out, \my $err );
    is( $? >> 8, 0, 'setup-ufw-metadata exits clean' ) or diag $err;
    return map { $_ => File::Slurper::read_text("$dir/$_") } keys %packaged;
}

# The filter table of $rules, from its header to its COMMIT.
sub filter_table {
    my ($rules) = @_;
    my ($table) = $rules =~ m/^(\*filter\n.*?^COMMIT$)/ms;
    return $table // q{};
}

my $v4 = '-A ufw-before-output -d 192.0.2.254 -m owner ! --uid-owner 0 -j REJECT';       ## no critic (RegularExpressions::ProhibitRegexInStrings) -- a literal, which every match that uses it quotes with \Q
my $v6 = '-A ufw6-before-output -d 2001:db8::254 -m owner ! --uid-owner 0 -j REJECT';    ## no critic (RegularExpressions::ProhibitRegexInStrings) -- a literal, which every match that uses it quotes with \Q

subtest 'each address goes to the rules of its own IP version' => sub {
    my %rules = run_on( '192.0.2.254', '2001:db8::254' );

    my $filter4 = filter_table( $rules{'before.rules'} );
    my $filter6 = filter_table( $rules{'before6.rules'} );
    like( $filter4, qr/^\Q$v4\E$/m, 'the IPv4 address is refused to everyone but root, in the filter table of before.rules' );
    like( $filter6, qr/^\Q$v6\E$/m, 'and the IPv6 address in the filter table of before6.rules' );

    unlike( $rules{'before.rules'},  qr/2001:db8/,  'iptables-restore is not handed an IPv6 address, which it refuses' );
    unlike( $rules{'before6.rules'}, qr/192\.0\.2/, 'and ip6tables-restore no IPv4 address' );

    # Established traffic is accepted first, so the rule judges only the
    # connections that the process opens.
    like( $filter4, qr/ESTABLISHED.*\Q$v4\E/s, 'the rule comes after the accept of established traffic' );
};

subtest 'a second run replaces the block and does not add another' => sub {
    my %rules = run_on( '192.0.2.254', '2001:db8::254' );
    foreach my $file ( sort keys %rules ) {
        my $blocks = () = $rules{$file} =~ m/^\#[ ]BEGIN[ ]trog-provisioner[ ]metadata[ ]service$/gm;
        is( $blocks, 1, "$file has the block once" );
    }
};

subtest 'an address that is no longer configured is no longer refused' => sub {
    my %rules = run_on('192.0.2.254');
    like( $rules{'before.rules'}, qr/^\Q$v4\E$/m, 'the address that is left stays' );
    is( $rules{'before6.rules'}, $packaged{'before6.rules'}, 'and before6.rules is as ufw packaged it' );

    %rules = run_on();
    is_deeply( \%rules, \%packaged, 'with no address, both files are as ufw packaged them' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
