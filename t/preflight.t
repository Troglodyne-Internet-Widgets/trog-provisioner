#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/preflight.t - bin/preflight: what it checks, and what it tells you to do about it

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Temp qw{tempdir};

use FindBin;
use FindBin::libs;

## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

use Trog::HV();

my $script = "$FindBin::Bin/../bin/preflight";
require_ok($script) or BAIL_OUT("$script does not load; the install is incomplete");

sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? ($result[0], $out) : $result[0];
}

subtest 'libvirt packs its version into one integer' => sub {
    is(Trog::Bin::Preflight::libvirt_version(10000000), '10.0.0',  'major only');
    is(Trog::Bin::Preflight::libvirt_version(9004000),  '9.4.0',   'and minor');
    is(Trog::Bin::Preflight::libvirt_version(8000012),  '8.0.12',  'and release');
};

subtest 'Sys::Virt has to be in step with the hypervisor' => sub {
    # Sys::Virt binds the API of the libvirt release it was built against, so a
    # mismatch shows up as a missing constant rather than as a version error.
    my $hv = Test::MockModule->new('Trog::HV');
    my $sv = Test::MockModule->new('Sys::Virt');

    $hv->redefine(vmm => sub { bless {}, 'Sys::Virt' });
    $sv->redefine(get_library_version => sub { 10000000 });

    $sv->redefine(VERSION => sub { '10.0.0' });
    my ($result, $out) = quietly(sub { Trog::Bin::Preflight::check_sys_virt_in_step(Trog::HV->new()) });
    ok($result->{ok}, 'the same release passes');
    like($out, qr/Sys::Virt 10\.0\.0 matches libvirt 10\.0\.0/, 'saying both versions');

    # A release apart in either direction is out of step.
    foreach my $version (qw{9.4.0 11.0.0}) {
        $sv->redefine(VERSION => sub { $version });
        ($result, $out) = quietly(sub { Trog::Bin::Preflight::check_sys_virt_in_step(Trog::HV->new()) });
        ok(!$result->{ok}, "$version against 10.0.0 fails");
        like($result->{fix}, qr/bring this machine to 10\.0\.0/, 'and says which way to move');
    }

    # A patch release apart is not: lockstep is on major.minor.
    $sv->redefine(get_library_version => sub { 10000004 });
    $sv->redefine(VERSION => sub { '10.0.0' });
    ($result) = quietly(sub { Trog::Bin::Preflight::check_sys_virt_in_step(Trog::HV->new()) });
    ok($result->{ok}, '10.0.0 against 10.0.4 is in step');
};

subtest 'a hypervisor that will not answer is reported, not thrown' => sub {
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine(vmm => sub { die "no route to host\n" });

    my ($result, $out) = quietly(sub { Trog::Bin::Preflight::check_libvirt(Trog::HV->new()) });
    ok(!$result->{ok}, 'libvirt check fails');

    ($result) = quietly(sub { Trog::Bin::Preflight::check_sys_virt_in_step(Trog::HV->new()) });
    ok(!$result->{ok}, 'and so does the version check, rather than dying on the way');
    like($result->{fix}, qr/Fix that first/, 'pointing at the one above it');
};

subtest 'passwordless sudo is the one that would hang the run' => sub {
    my $hv = Test::MockModule->new('Trog::HV');

    $hv->redefine(run => sub { 0 });
    my ($result) = quietly(sub { Trog::Bin::Preflight::check_passwordless_sudo(Trog::HV->new()) });
    ok($result->{ok}, 'sudo -n succeeding passes');

    $hv->redefine(run => sub { 1 });
    ($result) = quietly(sub { Trog::Bin::Preflight::check_passwordless_sudo(Trog::HV->new()) });
    ok(!$result->{ok}, 'and failing does not');
    like($result->{fix}, qr/NOPASSWD/,  'the guidance is the sudoers line');
    like($result->{fix}, qr/hangs rather than failing/, 'and says why it matters more than it looks');
    like($result->{fix}, qr/take it away again/, 'and that it is a real grant of root');
};

subtest 'the configuration it copies from has to be there' => sub {
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my ($result, $out) = quietly(sub { Trog::Bin::Preflight::check_config(Trog::HV->new()) });
    ok(!$result->{ok}, 'an empty directory fails');
    like($out, qr/ipmap\.cfg, recipes\.yaml/, 'naming what is missing');

    foreach my $file (qw{ipmap.cfg recipes.yaml}) {
        open(my $fh, '>', "$dir/$file") or die $!;
        close $fh;
    }
    ($result) = quietly(sub { Trog::Bin::Preflight::check_config(Trog::HV->new()) });
    ok($result->{ok}, 'and passes once they are there');
};

subtest 'every check reports rather than dying, so one run gets the whole list' => sub {
    # Being told about the sudo, and then a fix later about the missing
    # xorriso, is two round trips where one would do.
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine(is_local  => sub { 1 });
    $hv->redefine(run       => sub { 1 });          # no passwordless sudo
    $hv->redefine(iso_maker => sub { die "none\n" });
    $hv->redefine(vmm       => sub { die "no\n" });

    my $dir = tempdir(CLEANUP => 1);
    local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

    my ($rc, $out) = quietly(sub { Trog::Bin::Preflight::main() });
    is($rc, 1, 'exits non-zero');

    like($out, qr/sudo/,          'the sudo failure is in there');
    like($out, qr/ISO builder/,   'and the ISO builder');
    like($out, qr/libvirt/,       'and libvirt');
    like($out, qr/Missing from/,  'and the configuration');
    like($out, qr/5 things to fix first/, 'counted, all in one run');
};

done_testing();
