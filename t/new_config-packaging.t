#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

# A -f or -x in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

use Test::More;
use File::Temp();
use Text::Xslate();

# Deliberately not t/new_config.t: that one runs under Test::MockFile in strict
# mode, and what is here is about files that really are on disk -- the scripts in
# the checkout, and the copies of them made next to a domain's configuration.
require_ok( "$FindBin::Bin/../bin/new_config" ) or die "could not require SUT: $@";

subtest "the helper scripts ride along in the tarball" => sub {
    # They used to be rsynced off the hypervisor from the generator's own checkout
    # this checkout's path.  The hypervisor's checkout is somewhere else, so the
    # guest asked for a directory that was not there:
    #   rsync: [sender] change_dir "/home/.../scripts" failed: No such file...
    my $checkout = "$FindBin::Bin/..";
    my $cfg_dir  = File::Temp::tempdir(CLEANUP => 1);

    my @packed = Trog::Provisioner::Config::Generator::pack_scripts($checkout, $cfg_dir);

    ok(scalar @packed, 'something got packed');
    is_deeply([sort @packed], [@packed], 'in a stable order, so the tarball is reproducible');
    like($_, qr{\Ascripts/}, "$_ is stored under scripts/") for $packed[0];

    my @source = sort grep { -f "$checkout/scripts/$_" }
        do { opendir(my $dh, "$checkout/scripts") or die $!; grep { !m/\A\.\.?\z/ } readdir $dh };
    is(scalar @packed, scalar @source, 'all of them, not some of them');

    for my $rel (@packed) {
        ok(-f "$cfg_dir/$rel", "$rel landed in the domain directory");
    }

    # Every one of these is run on the guest; File::Copy makes no promise about
    # the executable bit, so it is set deliberately and worth checking.
    my ($exe) = grep { -x "$checkout/$_" } @packed;
    ok(defined $exe, 'at least one source script is executable') and
        ok(-x "$cfg_dir/$exe", "$exe is still executable after packing");

    # A second run must not accumulate what a previous one left behind.
    open(my $fh, '>', "$cfg_dir/scripts/stale") or die $!;
    close $fh;
    my @again = Trog::Provisioner::Config::Generator::pack_scripts($checkout, $cfg_dir);
    is_deeply(\@again, \@packed, 'a rerun packs the same set');
    ok(!-e "$cfg_dir/scripts/stale", 'and clears out what it found there');
};

subtest "the Makefile moves the scripts rather than fetching them" => sub {
    # Configured the way new_config configures it; a bare Xslate has no tabinate.
    my $xslate = Text::Xslate->new(
        path     => ["$FindBin::Bin/../templates"],
        syntax   => 'TTerse',
        function => { tabinate => Text::Xslate::html_builder(sub { $_[0] }) },
    );
    my $out = $xslate->render_string(_slurp("$FindBin::Bin/../templates/makefile.tt"),
            { state_dir => '/etc/provisioner/state/vm', script_dir => '/root/bin' });

    like($out, qr{^\tmv scripts/\* /root/bin/$}m, 'moves them out of the extracted tarball');
    unlike($out, qr{rsync.*scripts}, 'and does not go back to the hypervisor for them');
};

sub _slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Could not read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

done_testing();
