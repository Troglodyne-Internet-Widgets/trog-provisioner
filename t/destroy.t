#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text read_text};
use Pod::Usage();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
use Trog::HV();

require_ok("$FindBin::Bin/../bin/destroy")
  or BAIL_OUT('bin/destroy does not load; the install is incomplete');

# Point the hypervisor's domain dir at a temp tree.  Everything else in the
# script picks this same object back up with Trog::HV->new().
my $tmpdir = tempdir(CLEANUP => 1);
Trog::HV->forget();
Trog::HV->new(domain_dir => $tmpdir);

sub make_domain_dir {
    my ($domain) = @_;
    my $dir = "$tmpdir/$domain";
    make_path($dir);
    # Write a fake pubkey
    write_text("$dir/key.rsa.pub", "ssh-rsa AAAA fake-key-$domain comment\n");
    return $dir;
}

# --- remove_rsyslog_config ---
subtest 'remove_rsyslog_config skips missing file cleanly' => sub {
    # Just verify it doesn't die when the file doesn't exist
    eval { Trog::Bin::Destroy::remove_rsyslog_config('nonexistent.example', 1) };
    is($@, '', 'no exception for missing rsyslog config in dryrun');
};

# --- destroy_disks ---
subtest 'destroy_disks removes the guest disks and nothing shared' => sub {
    my $domain = 'test.example';

    my (@deleted, %exists);
    %exists = map { $_ => 1 } ("$domain-qcow2", "$domain-cloudinit.iso", 'baseimage-qcow2');

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine(volume        => sub { $exists{ $_[1] } });
    $hv_mock->redefine(delete_volume => sub { push @deleted, $_[1]; return 1 });

    Trog::Bin::Destroy::destroy_disks($domain, 1);
    is_deeply(\@deleted, [], 'dryrun removes nothing');

    Trog::Bin::Destroy::destroy_disks($domain, 0);
    is_deeply([sort @deleted], ["$domain-cloudinit.iso", "$domain-qcow2"],
        'the guest disk and its seed go');
    ok(!(grep { m/baseimage/ } @deleted),
        'and the base image, which every other guest is layered on, does not');
};

# --- remove_authorized_key ---
subtest 'remove_authorized_key removes only the domain key' => sub {
    my $domain = 'remove-key.example';
    make_domain_dir($domain);

    my $fake_home = tempdir(CLEANUP => 1);
    make_path("$fake_home/.ssh");
    my $ak = "$fake_home/.ssh/authorized_keys";

    my $domain_key = "ssh-rsa AAAA fake-key-$domain comment";
    my $other_key  = "ssh-rsa BBBB other-key other-comment";
    write_text($ak, "$other_key\n$domain_key\n");

    local $ENV{HOME} = $fake_home;

    Trog::Bin::Destroy::remove_authorized_key($domain, 0);

    my $after = read_text($ak);
    unlike($after, qr/\Qfake-key-$domain\E/, 'domain key removed');
    like($after,   qr/\Qother-key\E/,        'other key preserved');
};

subtest 'remove_authorized_key dryrun leaves file unchanged' => sub {
    my $domain = 'dryrun-key.example';
    make_domain_dir($domain);

    my $fake_home = tempdir(CLEANUP => 1);
    make_path("$fake_home/.ssh");
    my $ak = "$fake_home/.ssh/authorized_keys";

    my $domain_key = "ssh-rsa AAAA fake-key-$domain comment";
    write_text($ak, "$domain_key\n");

    local $ENV{HOME} = $fake_home;

    Trog::Bin::Destroy::remove_authorized_key($domain, 1);

    my $after = read_text($ak);
    like($after, qr/\Qfake-key-$domain\E/, 'dryrun: key not removed');
};

# --- purge_domain_dir ---
subtest 'purge_domain_dir removes domain directory' => sub {
    my $domain = 'purge.example';
    my $dir = make_domain_dir($domain);

    ok(-d $dir, 'domain dir exists before purge');
    Trog::Bin::Destroy::purge_domain_dir($domain, 0);
    ok(!-d $dir, 'domain dir removed after purge');
};

subtest 'purge_domain_dir dryrun leaves directory intact' => sub {
    my $domain = 'purge-dryrun.example';
    my $dir = make_domain_dir($domain);

    ok(-d $dir, 'domain dir exists before dryrun purge');
    Trog::Bin::Destroy::purge_domain_dir($domain, 1);
    ok(-d $dir, 'domain dir still exists after dryrun purge');
};

# --- main: missing domain ---
# pod2usage exits, so this has to be a real run.
subtest 'main exits with the usage when given no domain' => sub {
    my $out = qx{$^X "$FindBin::Bin/../bin/destroy" --dryrun 2>&1};
    isnt($?, 0, 'exits non-zero');
    like($out, qr/No domain passed/, 'saying what was missing');
    like($out, qr/Usage:/,           'and printing the usage out of the POD');
};

subtest 'the POD documents the interface' => sub {
    open(my $fh, '>', \my $text) or die $!;
    Pod::Usage::pod2usage(
        -input    => "$FindBin::Bin/../bin/destroy",
        -output   => $fh,
        -exitval  => 'NOEXIT',
        -verbose  => 99,
        -sections => 'SYNOPSIS|OPTIONS',
    );
    close $fh;

    like($text, qr/--purge/,   'POD documents --purge');
    like($text, qr/--dryrun/,  'POD documents --dryrun');
    like($text, qr/--connect/, 'POD documents --connect');
    like($text, qr/DOMAIN/,    'POD documents the DOMAIN argument');
};

done_testing;
