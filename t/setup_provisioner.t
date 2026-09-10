#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/setup_provisioner.t - what the install script is for, now that most of it is
somebody else's job

=head1 DESCRIPTION

Every step in the script is a stub, so there is no behaviour to assert on.  What
there is, and what this pins, is the B<scope>: this script is about the machine
that hosts guests, and the machine that runs the provisioner is a guest that
L<Provisioner::Recipe::trogrunner> builds.

That distinction is the whole of what went wrong with the file before -- it
tried to be both, and so it configured an rsyslog listener on whichever machine
you happened to run it from.

=cut

use Test::More;
use Pod::Usage();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../bin/setup_provisioner";
require_ok($script) or BAIL_OUT("$script does not load");

subtest 'the steps are the ones a hypervisor needs, and their numbers are the exit codes' => sub {

    # A step returning false is what main() reports, by position.  Renumbering
    # is free while every step is a stub and expensive once one is not, which
    # is the argument for pinning the order now.
    my @steps = qw{
      setup_kvm
      setup_public_bridge
      setup_iso_builder
      setup_storage_pool
      setup_apparmor
      setup_firewall
    };

    foreach my $step (@steps) {
        can_ok( 'Trog::Bin::SetupProvisioner', $step );
    }

    is( Trog::Bin::SetupProvisioner::main(), 0, 'all of them pass, all of them being stubs' );

    foreach my $i ( 0 .. $#steps ) {
        ## no critic (ProhibitNoStrict, ProhibitNoWarningsRedefine) -- the whole assertion is which position in main() a failing step maps to, and the only way to make one fail is to replace it.
        no strict 'refs';
        no warnings 'redefine';
        my $name = "Trog::Bin::SetupProvisioner::$steps[$i]";
        local *{$name} = sub { 0 };
        is( Trog::Bin::SetupProvisioner::main(), $i + 1, "$steps[$i] failing is exit " . ( $i + 1 ) );
    }
};

subtest 'what moved out has not quietly moved back' => sub {

    # auditd, fail2ban, cron and a management interface are recipes: a guest to
    # build rather than a step to run on the hypervisor.  A step here with one
    # of those names is somebody having forgotten that.
    foreach my $gone (qw{setup_auditd setup_fail2ban setup_crons setup_management_interface setup_rsyslog}) {
        ok( !Trog::Bin::SetupProvisioner->can($gone), "no $gone: that is a recipe" );
    }
};

subtest 'the POD says which machine this is about' => sub {
    my $description = _pod_section( $script, 'DESCRIPTION' );

    like( $description, qr/hypervisor/, 'the machine that hosts guests' );
    like( $description, qr/trogrunner/, 'and where the machine that runs the provisioner comes from instead' );
};

sub _pod_section {
    my ( $file, $section ) = @_;
    my $out = q{};
    open( my $fh, '>', \$out ) or die $!;
    Pod::Usage::pod2usage(
        -input   => $file, -output   => $fh, -exitval => 'NOEXIT',
        -verbose => 99,    -sections => $section,
    );
    close $fh;
    return $out;
}

done_testing;
