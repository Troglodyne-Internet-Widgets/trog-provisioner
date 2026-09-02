#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text read_text};
use Pod::Usage();

use FindBin;
use FindBin::libs;
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

# --- remove_tf_configs ---
subtest 'remove_tf_configs removes matching files' => sub {
    my $domain = 'test.example';

    # tf_config_dir comes off the hypervisor now, so we can point it somewhere
    # writable and check the real thing rather than a re-implementation of it.
    my $tfdir = tempdir(CLEANUP => 1);
    Trog::HV->forget();
    Trog::HV->new(domain_dir => $tmpdir, tf_dir => $tfdir);
    make_path("$tfdir/config");

    my @expected = map { "$tfdir/config/$domain.$_" } qw{tf cloud_init.cfg network_config.cfg};
    write_text($_, "# placeholder\n") for @expected;
    my $bystander = "$tfdir/config/other.example.tf";
    write_text($bystander, "# placeholder\n");

    Trog::Bin::Destroy::remove_tf_configs($domain, 1);
    ok(-f $_, "dryrun left $_ alone") for @expected;

    Trog::Bin::Destroy::remove_tf_configs($domain, 0);
    ok(!-f $_, "removed $_") for @expected;
    ok(-f $bystander, 'another domain\'s config was left alone');

    Trog::HV->forget();
    Trog::HV->new(domain_dir => $tmpdir);
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
