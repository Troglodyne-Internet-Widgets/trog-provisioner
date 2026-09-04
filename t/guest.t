#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';


=head1 NAME

t/guest.t - Trog::Guest: what a freshly built guest has to be waited for

=cut

# A -f or -x in here is asserting on a file this test just made, in a temporary
# directory nothing else can see.  There is no window for it to be wrong in, so
# the TOCTOU policies have nothing to catch.
## no critic (ValuesAndExpressions::ProhibitFiletest_f, ValuesAndExpressions::ProhibitFiletest_rwxRWX)

use Test::More;
use File::Temp();
use Test::MockModule qw{strict};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
use Trog::Guest();

# A guest and a hypervisor reach their far side the same way, so the transport
# is Trog::Machine's and is tested in t/hv.t.  What is here is the rest.

subtest 'a guest needs somewhere to connect to' => sub {
    eval { Trog::Guest->new(user => 'ubuntu') };
    like($@, qr/needs a host/, 'refuses to be built without one');
};

subtest 'identity' => sub {
    my $guest = Trog::Guest->new(name => 'vm.example.com', host => '203.0.113.10',
        user => 'ubuntu', key_path => '/opt/domains/vm.example.com/key.rsa');

    is($guest->name,       'vm.example.com', 'name');
    is($guest->ssh_host,   '203.0.113.10',   'host');
    is($guest->ssh_user,   'ubuntu',         'user');
    is($guest->ssh_port,   22,               'the usual port');
    is($guest->ssh_target, 'ubuntu@203.0.113.10', 'ssh target');
    ok(!$guest->is_local, 'a guest is never us');
    is($guest->describe, 'vm.example.com (ubuntu@203.0.113.10)', 'says both in errors');

    is(Trog::Guest->new(host => '203.0.113.11')->name, '203.0.113.11',
        'an unnamed guest answers to its address');
};

# --- Waiting ------------------------------------------------------------------
subtest 'wait_for_ssh wants the port open and the connection made' => sub {
    my $guest = Trog::Guest->new(name => 'vm.example.com', host => '203.0.113.10', user => 'ubuntu');

    my $ports = Test::MockModule->new('Net::EmptyPort');
    my $machine = Test::MockModule->new('Trog::Machine');

    $ports->redefine(wait_port => sub { 0 });
    eval { quietly(sub { $guest->wait_for_ssh(timeout => 1) }) };
    like($@, qr/never came up after 1s/, 'a port that never opens is an error');
    like($@, qr/vm\.example\.com/,       'naming the guest');

    # A port that opens but a connection that will not: checking only the first
    # is how you get a confusing failure three steps later.
    $ports->redefine(wait_port => sub { 1 });
    $machine->redefine(ssh => sub { undef });
    eval { quietly(sub { $guest->wait_for_ssh }) };
    like($@, qr/Could not establish an SSH connection/, 'and so is that');

    $machine->redefine(ssh => sub { bless {}, 'FakeSSH' });
    is(quietly(sub { $guest->wait_for_ssh }), $guest, 'otherwise we get the guest back');
};

subtest 'wait_for_cloud_init re-runs the modules that failed' => sub {
    my $guest = Trog::Guest->new(name => 'vm.example.com', host => '203.0.113.10', user => 'ubuntu');

    my @ran;
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine(run      => sub { my ($s, @c) = @_; push @ran, join(' ', @c); return 0 });
    $machine->redefine(run_sudo => sub { my ($s, @c) = @_; push @ran, 'sudo ' . join(' ', @c); return 0 });
    $machine->redefine(capture => sub {
        my ($s, $cmd) = @_;
        push @ran, $cmd;
        return '[{"name":"modules-final/config-foo","result":"FAIL"},'
             . '{"name":"modules-config/config-bar","result":"SUCCESS"}]'
          if index($cmd, 'analyze dump') >= 0;
        return 're-ran it';
    });

    ok(quietly(sub { $guest->wait_for_cloud_init('vm.example.com') }), 'finishes');

    ok((grep { index($_, 'Boot configuration complete') >= 0 } @ran), 'waited for the boot to report complete');
    ok((grep { index($_, 'sudo rm /var/lib/cloud/instances/vm.example.com/sem/config_foo') >= 0 } @ran),
        'removed the semaphore of the module that failed');
    ok((grep { index($_, 'cloud-init single --name foo') >= 0 } @ran), 'and re-ran it');
    ok(!(grep { index($_, '--name bar') >= 0 } @ran), 'left the one that succeeded alone');
};

subtest 'a cloud-init that reports failure is fatal' => sub {
    my $guest = Trog::Guest->new(host => '203.0.113.10', user => 'ubuntu');

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine(run      => sub { 1 });
    $machine->redefine(run_sudo => sub { 1 });
    $machine->redefine(capture  => sub { '[]' });

    eval { quietly(sub { $guest->wait_for_cloud_init('vm.example.com') }) };
    like($@, qr/Cloud init reported failure/, 'dies');
};

subtest 'cloud-init that does not return JSON is fatal' => sub {
    my $guest = Trog::Guest->new(host => '203.0.113.10', user => 'ubuntu');

    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine(run      => sub { 0 });
    $machine->redefine(run_sudo => sub { 0 });
    $machine->redefine(capture  => sub { 'command not found' });

    eval { quietly(sub { $guest->wait_for_cloud_init('vm.example.com') }) };
    like($@, qr/did not return a JSON array/, 'dies rather than carrying on blind');
};

subtest 'wait_for_makefile waits for the queue twice' => sub {
    my $guest = Trog::Guest->new(name => 'vm.example.com', host => '203.0.113.10', user => 'ubuntu');

    my @ran;
    my $machine = Test::MockModule->new('Trog::Machine');
    $machine->redefine(run      => sub { my ($s, @c) = @_; push @ran, join(' ', @c); return 0 });
    $machine->redefine(run_sudo => sub { my ($s, @c) = @_; push @ran, 'sudo ' . join(' ', @c); return 0 });
    $machine->redefine(capture  => sub { 'the last few lines' });

    ok(quietly(sub { $guest->wait_for_makefile('vm.example.com') }), 'finishes');

    my @queue = grep { index($_, 'atq') >= 0 } @ran;
    is(scalar @queue, 2, 'twice, because the Makefile may queue work of its own');
    ok((grep { index($_, 'until [ -f /var/log/vm.example.com.setup.log ]') >= 0 } @ran), 'waited for the log to appear');
    ok((grep { index($_, 'while lsof | grep /var/log/vm.example.com.setup.log') >= 0 } @ran), 'and to stop being written');
};

# These print their progress; the tests do not need to read it.
sub quietly {
    my ($code) = @_;
    open(my $capture, '>', \my $out) or die $!;
    my @result = do { local *STDOUT = $capture; $code->() };
    close $capture;
    return wantarray ? @result : $result[0];
}

done_testing;
