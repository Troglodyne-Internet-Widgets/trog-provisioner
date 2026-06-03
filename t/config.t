#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp qw{tempdir tempfile};
use Test::More;

use Trog::Provisioner::Config;

# ---- helpers ----

sub write_conf {
    my (%fields) = @_;
    my ( $fh, $fname ) = tempfile( SUFFIX => '.conf', UNLINK => 1 );
    for my $k ( sort keys %fields ) {
        print $fh "$k=$fields{$k}\n";
    }
    close $fh;
    return $fname;
}

my %VALID = (
    image          => 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
    size           => '42949672960',
    ips            => '10.0.0.5/24',
    gateway        => '10.0.0.1',
    resolvers      => '8.8.8.8, 8.8.4.4',
    dhcp_devname   => 'enp3s0',
    bridge_devname => 'br0',
    contact_email  => 'ops@example.com',
);

# ---- 1. load() on a missing file ----

{
    my ( $cfg, $errs ) = Trog::Provisioner::Config->load('/nonexistent/path/provision.conf');
    ok( !defined $cfg, 'load: undef config for missing file' );
    like( $errs->[0], qr/not found/, 'load: descriptive error for missing file' );
}

# ---- 2. load() + validate() on a fully valid config ----

{
    my $f = write_conf(%VALID);
    my ( $cfg, $errs ) = Trog::Provisioner::Config->load($f);
    ok( defined $cfg, 'load: returns config object for valid file' );
    is( scalar @$errs, 0, 'load: no errors for valid config' ) or diag join "\n", @$errs;
}

# ---- 3. validate(): each required field triggers an error when missing ----

for my $missing_field (@Trog::Provisioner::Config::REQUIRED_FIELDS) {
    my %partial = %VALID;
    delete $partial{$missing_field};
    my $f = write_conf(%partial);
    my ( $cfg, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /\Q$missing_field\E/ } @$errs;
    ok( scalar @relevant >= 1, "validate: error reported for missing '$missing_field'" )
        or diag "errors: " . join( ', ', @$errs );
}

# ---- 4. validate(): invalid URL for 'image' ----

{
    my $f = write_conf( %VALID, image => 'ftp://bad-scheme' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /image/ } @$errs;
    ok( @relevant, 'validate: rejects non-http(s) image URL' );
}

# ---- 5. validate(): invalid size (non-integer) ----

{
    my $f = write_conf( %VALID, size => 'forty-two-gb' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /size/ } @$errs;
    ok( @relevant, 'validate: rejects non-integer size' );
}

# ---- 6. validate(): invalid gateway IP ----

{
    my $f = write_conf( %VALID, gateway => 'not-an-ip' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /gateway/ } @$errs;
    ok( @relevant, 'validate: rejects non-IP gateway' );
}

# ---- 7. validate(): invalid email ----

{
    my $f = write_conf( %VALID, contact_email => 'no-at-sign' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /contact_email/ } @$errs;
    ok( @relevant, 'validate: rejects malformed email' );
}

# ---- 8. validate(): invalid devname (spaces not allowed) ----

{
    my $f = write_conf( %VALID, bridge_devname => 'my bridge' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /bridge_devname/ } @$errs;
    ok( @relevant, 'validate: rejects devname with spaces' );
}

# ---- 9. validate(): IP list with one bad entry ----

{
    my $f = write_conf( %VALID, resolvers => '8.8.8.8, 999.0.0.1' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /resolvers/ } @$errs;
    ok( @relevant, 'validate: rejects resolver list containing an invalid IP' );
}

# ---- 10. validate(): zero not a valid positive integer ----

{
    my $f = write_conf( %VALID, size => '0' );
    my ( undef, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /size/ } @$errs;
    ok( @relevant, 'validate: rejects size of zero' );
}

# ---- 11. validate(): CIDR-suffixed IP accepted for 'ips' ----

{
    my $f = write_conf( %VALID, ips => '192.168.1.100/24' );
    my ( $cfg, $errs ) = Trog::Provisioner::Config->load($f);
    my @relevant = grep { /ips/ } @$errs;
    ok( !@relevant, 'validate: accepts CIDR-notated IP in ips field' )
        or diag join "\n", @$errs;
}

# ---- 12. check_domain_files(): reports missing files ----

{
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/mydom";
    my @errs = Trog::Provisioner::Config->check_domain_files( $tmpdir, 'mydom' );
    is( scalar @errs, 2, 'check_domain_files: reports both missing files' );
    like( $errs[0], qr/users\.yaml|data\.tar\.gz/, 'check_domain_files: names the missing file' );
}

# ---- 13. check_domain_files(): no errors when files exist ----

{
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/mydom";
    open my $f1, '>', "$tmpdir/mydom/users.yaml"  or die $!; close $f1;
    open my $f2, '>', "$tmpdir/mydom/data.tar.gz" or die $!; close $f2;
    my @errs = Trog::Provisioner::Config->check_domain_files( $tmpdir, 'mydom' );
    is( scalar @errs, 0, 'check_domain_files: no errors when both files present' );
}

# ---- 14. check_system_prereqs(): returns error for unknown tool ----

{
    my $fake_which = sub { return undef };    # nothing found
    my @errs = Trog::Provisioner::Config->check_system_prereqs($fake_which);
    ok( scalar @errs >= 4, 'check_system_prereqs: reports all four missing tools' );
    like( join( "\n", @errs ), qr/terraform/, 'check_system_prereqs: names terraform' );
    like( join( "\n", @errs ), qr/virsh/,     'check_system_prereqs: names virsh' );
}

# ---- 15. check_system_prereqs(): no tool errors when everything found ----

{
    my $fake_which = sub { return '/usr/bin/fake' };    # everything "found"
    my @errs = Trog::Provisioner::Config->check_system_prereqs($fake_which);
    my @tool_errs = grep { /not found/ } @errs;
    is( scalar @tool_errs, 0, 'check_system_prereqs: no tool errors when all present' );
}

# ---- 16. check_config main(): exits 1 for missing provision.conf ----

{
    BEGIN {
        $INC{'File/Which.pm'} = 1;
        package File::Which;
        use Exporter;
        our @EXPORT_OK = qw{which};
        sub which { return '/usr/bin/fake' }
    }

    require "$FindBin::Bin/../bin/check_config";

    my $tmpdir = tempdir( CLEANUP => 1 );
    my $rc = Trog::Bin::CheckConfig::main( "--domaindir=$tmpdir", 'nosuchdomain' );
    is( $rc, 1, 'check_config main: returns 1 for domain with no provision.conf' );
}

# ---- 17. check_config main(): exits 0 for valid domain ----

{
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/mydom";

    # Write valid provision.conf
    open my $cf, '>', "$tmpdir/mydom/provision.conf" or die $!;
    print $cf "$_=$VALID{$_}\n" for keys %VALID;
    close $cf;

    # Create required files
    open my $f1, '>', "$tmpdir/mydom/users.yaml"  or die $!; close $f1;
    open my $f2, '>', "$tmpdir/mydom/data.tar.gz" or die $!; close $f2;

    # Stub check_system_prereqs so no real tools are needed
    no warnings 'redefine';
    local *Trog::Provisioner::Config::check_system_prereqs = sub { return () };

    my $rc = Trog::Bin::CheckConfig::main( "--domaindir=$tmpdir", 'mydom' );
    is( $rc, 0, 'check_config main: returns 0 for valid domain' );
}

done_testing();
