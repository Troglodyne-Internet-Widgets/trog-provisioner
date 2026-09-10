#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/destroy.t - bin/destroy: tearing a guest down without taking its neighbours

=cut

use Test::More;
use IPC::Run3();
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Path       qw{make_path};
use File::Slurper();
use File::Slurper::Temp();
use Pod::Usage();

use FindBin;
use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use Trog::HV();
## no critic (ProhibitUnusedImports) -- Test::MockModule in strict mode will not mock a package that is not loaded.
use Provisioner::Cookbook();

require_ok("$FindBin::Bin/../bin/destroy")
  or BAIL_OUT('bin/destroy does not load; the install is incomplete');

# Point the hypervisor's domain dir at a temp tree.  Everything else in the
# script picks this same object back up with Trog::HV->new().
my $tmpdir = tempdir( CLEANUP => 1 );
Trog::HV->forget();
Trog::HV->new( domain_dir => $tmpdir );

sub make_domain_dir {
    my ($domain) = @_;
    my $dir = "$tmpdir/$domain";
    make_path($dir);

    # Write a fake pubkey
    File::Slurper::Temp::write_text( "$dir/key.rsa.pub", "ssh-rsa AAAA fake-key-$domain comment\n" );
    return $dir;
}

# --- destroy_disks ---
subtest 'destroy_disks removes the guest disks and nothing shared' => sub {
    my $domain = 'test.example';

    my ( @deleted, %exists );
    %exists = map { $_ => 1 } ( "$domain-qcow2", "$domain-cloudinit.iso", 'baseimage-qcow2' );

    my $hv_mock = Test::MockModule->new('Trog::HV');
    $hv_mock->redefine( volume        => sub { $exists{ $_[1] } } );
    $hv_mock->redefine( delete_volume => sub { push @deleted, $_[1]; return 1 } );

    Trog::Bin::Destroy::destroy_disks( $domain, 1 );
    is_deeply( \@deleted, [], 'dryrun removes nothing' );

    Trog::Bin::Destroy::destroy_disks( $domain, 0 );
    is_deeply(
        [ sort @deleted ], [ "$domain-cloudinit.iso", "$domain-qcow2" ],
        'the guest disk and its seed go'
    );
    ok(
        !( grep { index( $_, 'baseimage' ) >= 0 } @deleted ),
        'and the base image, which every other guest is layered on, does not'
    );
};

# --- remove_authorized_key ---
subtest 'remove_authorized_key removes only the domain key' => sub {
    my $domain = 'remove-key.example';
    make_domain_dir($domain);

    my $fake_home = tempdir( CLEANUP => 1 );
    make_path("$fake_home/.ssh");
    my $ak = "$fake_home/.ssh/authorized_keys";

    my $domain_key = "ssh-rsa AAAA fake-key-$domain comment";
    my $other_key  = "ssh-rsa BBBB other-key other-comment";
    File::Slurper::Temp::write_text( $ak, "$other_key\n$domain_key\n" );

    local $ENV{HOME} = $fake_home;

    Trog::Bin::Destroy::remove_authorized_key( $domain, 0 );

    my $after = File::Slurper::read_text($ak);
    unlike( $after, qr/\Qfake-key-$domain\E/, 'domain key removed' );
    like( $after, qr/\Qother-key\E/, 'other key preserved' );
};

subtest 'remove_authorized_key dryrun leaves file unchanged' => sub {
    my $domain = 'dryrun-key.example';
    make_domain_dir($domain);

    my $fake_home = tempdir( CLEANUP => 1 );
    make_path("$fake_home/.ssh");
    my $ak = "$fake_home/.ssh/authorized_keys";

    my $domain_key = "ssh-rsa AAAA fake-key-$domain comment";
    File::Slurper::Temp::write_text( $ak, "$domain_key\n" );

    local $ENV{HOME} = $fake_home;

    Trog::Bin::Destroy::remove_authorized_key( $domain, 1 );

    my $after = File::Slurper::read_text($ak);
    like( $after, qr/\Qfake-key-$domain\E/, 'dryrun: key not removed' );
};

# --- remove_runner_key ---
#
# The counterpart of authorize_runner_key in bin/provision.  It reads the public
# half beside the domain rather than the store, so a destroy never stops to ask
# for a passphrase -- one that did is one nobody would run.
subtest 'a runner key comes off every hypervisor it was let in to' => sub {
    my $domain = 'runner.example';
    my $dir    = make_domain_dir($domain);

    my $pubkey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOTAREALKEYbutlongenough runner-key';
    File::Slurper::Temp::write_text( "$dir/hypervisor-key.pub", "$pubkey\n" );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine(
        domain_config => sub {
            return {
                trogrunner => {
                    hypervisor_access => 'least',
                    hypervisors       => {
                        one => { libvirt_uri => 'qemu+ssh://runner@one.test.test/system' },
                        two => { libvirt_uri => 'qemu+ssh://runner@two.test.test/system' },
                    },
                },
            };
        }
    );

    my %files = map { +( "$_.test.test" => "ssh-rsa BBBB somebody-else\n$pubkey\n" ) } qw{one two};
    my $hv    = Test::MockModule->new('Trog::HV');
    $hv->redefine( authorized_keys => sub { $_[0]->ssh_host } );
    $hv->redefine( file_exists     => sub { exists $files{ $_[1] } } );
    $hv->redefine( read_text       => sub { $files{ $_[1] } } );
    $hv->redefine( write_text      => sub { $files{ $_[1] } = $_[2]; return 1 } );

    Trog::Bin::Destroy::remove_runner_key( $domain, 0 );

    foreach my $host (qw{one.test.test two.test.test}) {
        unlike( $files{$host}, qr/\Qrunner-key\E/, "taken off $host" );
        like( $files{$host}, qr/somebody-else/, "and the other line on $host is still there" );
    }
};

subtest 'the key material goes, however the line around it was written' => sub {
    my $domain = 'runner-edited.example';
    my $dir    = make_domain_dir($domain);

    # Measured on a hypervisor: the same key had been authorized twice, once
    # bare and once with a from= restriction and a comment, because the line
    # bin/provision writes changed between two provisions.  Matching the whole
    # line takes one of them and leaves the other standing for a guest that no
    # longer exists.
    my $material = 'AAAAC3NzaC1lZDI1NTE5AAAAIJtNOTAREALKEYbutlongenough';
    File::Slurper::Temp::write_text( "$dir/hypervisor-key.pub", "ssh-ed25519 $material trog-provisioner runner $domain\n" );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { { trogrunner => { hypervisors => { one => { libvirt_uri => 'qemu+ssh://r@one.test.test/system' } } } } } );

    my %files = ( 'one.test.test' => qq{ssh-rsa BBBB somebody-else\nssh-ed25519 $material\nfrom="10.0.0.1" ssh-ed25519 $material trog-provisioner runner $domain\n} );
    my $hv    = Test::MockModule->new('Trog::HV');
    $hv->redefine( authorized_keys => sub { $_[0]->ssh_host } );
    $hv->redefine( file_exists     => sub { exists $files{ $_[1] } } );
    $hv->redefine( read_text       => sub { $files{ $_[1] } } );
    $hv->redefine( write_text      => sub { $files{ $_[1] } = $_[2]; return 1 } );

    Trog::Bin::Destroy::remove_runner_key( $domain, 0 );

    unlike( $files{'one.test.test'}, qr/\Q$material\E/, 'both of them are gone' );
    like( $files{'one.test.test'}, qr/somebody-else/, 'and nobody else lost theirs' );
};

subtest 'a public key that is not one matches nothing, and says so' => sub {
    my $domain = 'runner-bogus.example';
    my $dir    = make_domain_dir($domain);

    # An empty or truncated key would be a substring of half the file, which is
    # the one way this can lock somebody out of their own hypervisor.
    File::Slurper::Temp::write_text( "$dir/hypervisor-key.pub", "ssh-ed25519 short\n" );

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    $cookbook->redefine( domain_config => sub { { trogrunner => { hypervisors => { one => { libvirt_uri => 'qemu+ssh://r@one.test.test/system' } } } } } );

    my $touched = 0;
    my $hv      = Test::MockModule->new('Trog::HV');
    $hv->redefine( write_text => sub { $touched++; return 1 } );

    eval { Trog::Bin::Destroy::remove_runner_key( $domain, 0 ) };
    like( $@, qr/does not look like one; refusing/, 'refused rather than matched' );
    is( $touched, 0, 'and nothing was rewritten' );
};

subtest 'a domain that is not a runner is nothing to do' => sub {
    my $domain = 'plain.example';
    make_domain_dir($domain);

    my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
    my $asked    = 0;
    $cookbook->redefine( domain_config => sub { $asked++; return {} } );

    # No hypervisor-key.pub beside it, so it returns before it asks anything at
    # all -- which is what every guest that is not a runner looks like.
    Trog::Bin::Destroy::remove_runner_key( $domain, 0 );
    is( $asked, 0, 'the configuration is not even consulted' );
};

# --- purge_domain_dir ---
subtest 'purge_domain_dir removes domain directory' => sub {
    my $domain = 'purge.example';
    my $dir    = make_domain_dir($domain);

    ok( -d $dir, 'domain dir exists before purge' );
    Trog::Bin::Destroy::purge_domain_dir( $domain, 0 );
    ok( !-d $dir, 'domain dir removed after purge' );
};

subtest 'purge_domain_dir dryrun leaves directory intact' => sub {
    my $domain = 'purge-dryrun.example';
    my $dir    = make_domain_dir($domain);

    ok( -d $dir, 'domain dir exists before dryrun purge' );
    Trog::Bin::Destroy::purge_domain_dir( $domain, 1 );
    ok( -d $dir, 'domain dir still exists after dryrun purge' );
};

# --- main: missing domain ---
# pod2usage exits, so this has to be a real run.
subtest 'main exits with the usage when given no domain' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/destroy", '--dryrun' ], \undef, \$out, \$out );
    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/No domain passed/, 'saying what was missing' );
    like( $out, qr/Usage:/,           'and printing the usage out of the POD' );
};

subtest 'the POD documents the interface' => sub {
    open( my $fh, '>', \my $text ) or die $!;
    Pod::Usage::pod2usage(
        -input    => "$FindBin::Bin/../bin/destroy",
        -output   => $fh,
        -exitval  => 'NOEXIT',
        -verbose  => 99,
        -sections => 'SYNOPSIS|OPTIONS',
    );
    close $fh;

    like( $text, qr/--purge/,   'POD documents --purge' );
    like( $text, qr/--dryrun/,  'POD documents --dryrun' );
    like( $text, qr/--connect/, 'POD documents --connect' );
    like( $text, qr/DOMAIN/,    'POD documents the DOMAIN argument' );
};

done_testing;
