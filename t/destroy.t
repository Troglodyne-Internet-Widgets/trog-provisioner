#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/destroy.t - bin/destroy: tearing a guest down without taking its neighbors

=cut

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture capture_stdout};
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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it
use Provisioner::Cookbook();
use Trog::HV();

# Loaded so Test::MockModule has a package to attach to: Trog::HV requires its
# backend lazily, and it is named only as a string below.
use Trog::HV::Libvirt();      ## no critic (ProhibitUnusedImports)
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports)

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

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

    my $hv_mock = Test::MockModule->new('Trog::HV::Libvirt');
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

    like( exception { Trog::Bin::Destroy::remove_runner_key( $domain, 0 ) }, qr/does[ ]not[ ]look[ ]like[ ]one;[ ]refusing/, 'refused rather than matched' );
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
subtest 'a cloud keeps its own volumes' => sub {
    Trog::HV->forget();
    my $cloud = Trog::HV->new( cloud => 'testcloud' );

    # volume and delete_volume are libvirt nouns the cloud backend refuses to
    # pretend to; the volumes a cloud guest had went with the server, which is
    # where the decision about which of them were ours to delete lives.
    ok !defined Trog::Bin::Destroy::destroy_disks( 'vm.example.com', 0 ),
      'no volumes are looked for on a hypervisor that has none of that shape';

    Trog::HV->forget();
};

subtest 'main exits with the usage when given no domain' => sub {
    my $out = q{};
    IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/destroy", '--dryrun' ], \undef, \$out, \$out );
    isnt( $?, 0, 'exits non-zero' );
    like( $out, qr/No[ ]domain[ ]passed/, 'saying what was missing' );
    like( $out, qr/Usage:/,               'and printing the usage out of the POD' );
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
    close($fh) or die "Could not close the POD capture: $!";

    like( $text, qr/--purge/,      'POD documents --purge' );
    like( $text, qr/--dryrun/,     'POD documents --dryrun' );
    like( $text, qr/--connect/,    'POD documents --connect' );
    like( $text, qr/DOMAIN/,       'POD documents the DOMAIN argument' );
    like( $text, qr/--purge-data/, 'POD documents --purge-data' );
    like( $text, qr/--orphans/,    'POD documents --orphans' );
    like( $text, qr/--backups/,    'POD documents --backups' );
};

# --- the data directory, and the sweep for what runs left behind ---

# Enough of Sys::Virt to answer the one question the sweep asks of it.
{

    package Test::Libvirt;
    our @DOMAINS;

    sub list_all_domains {
        return map { bless { name => $_ }, 'Test::Libvirt::Domain' } @DOMAINS;
    }

    package Test::Libvirt::Domain;
    sub get_name ($self) { return $self->{name} }
}

# The pool a backup sweep reads, kept apart from the domain fake above because
# the two sweeps ask different questions of a hypervisor.
{

    package Test::Pool;
    our @VOLUMES;
    our $REFUSE = 0;

    sub list_all_volumes {
        die "cannot read the pool\n" if $REFUSE;
        return map { bless { name => $_ }, 'Test::Pool::Volume' } @VOLUMES;
    }

    package Test::Pool::Volume;
    sub get_name ($self) { return $self->{name} }
}

# The data source these act on.  No hypervisors.conf is written into the
# configuration directory, so the fleet is empty unless a subtest names one.
my $data = tempdir( CLEANUP => 1 );

sub write_config {
    my (%domains) = @_;

    my $yaml = "_base:\n    data:\n        from: $data\n        to: /opt/domains\n";
    $yaml .= "$_:\n    ntp:\n" for sort keys %domains;

    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", $yaml );
    Provisioner::Cookbook->forget();
    return;
}

# Both streams, because half of what the sweep has to say about refusing to do
# something is said on stderr.
sub says {
    my ($code) = @_;
    my ( $out, $err, @returned ) = capture { $code->() };
    return ( "$out$err", @returned );
}

subtest 'purge_data_dir takes the domain data directory, and dryrun does not' => sub {
    write_config( map { $_ => 1 } qw{gone.test kept.test never-was.test} );
    make_path("$data/$_") for qw{gone.test kept.test};

    says( sub { Trog::Bin::Destroy::purge_data_dir( 'kept.test', undef, 1 ) } );
    ok( -d "$data/kept.test", 'a dry run leaves it where it is' );

    says( sub { Trog::Bin::Destroy::purge_data_dir( 'gone.test', undef, 0 ) } );
    ok( !-e "$data/gone.test", 'and a real one takes it' );

    # Asked of a domain whose provision died before it made one.
    my ($said) = says( sub { Trog::Bin::Destroy::purge_data_dir( 'never-was.test', undef, 0 ) } );
    like( $said, qr/never-was\.test/, 'a directory that was never there is not an error' );

    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_base:\n    ntp:\n" );
    Provisioner::Cookbook->forget();
    ($said) = says( sub { Trog::Bin::Destroy::purge_data_dir( 'kept.test', undef, 0 ) } );
    like( $said, qr/says[ ]where[ ]the[ ]data[ ]source[ ]is/, 'with no data source it says there is nothing to remove' );
    ok( -d "$data/kept.test", 'rather than guessing where one is' );
    File::Path::remove_tree("$data/kept.test");
};

subtest 'the backup sweep takes the copies, which nothing else ever will' => sub {
    Trog::HV->forget();

    my @deleted;
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( pool => sub { bless {}, 'Test::Pool' } );
    $hv->redefine( delete_volume => sub { push @deleted, $_[1]; return 1 } );

    local @Test::Pool::VOLUMES = qw{live.test-qcow2 live.test-cloudinit.iso gone.test.bak-qcow2 live.test.bak-qcow2};

    my ($said) = says( sub { Trog::Bin::Destroy::sweep_backups( 'qemu:///system', undef, 1 ) } );
    like( $said, qr/gone\.test\.bak-qcow2/, 'the dry run names a copy' );
    like( $said, qr/2[ ]disks[ ]were/,      'and counts them in a sentence that agrees with itself' );
    like( $said, qr/live\.test\.bak-qcow2/, 'and the copy of a guest that is still here, since both are copies' );
    unlike( $said, qr/live\.test-qcow2/, 'and not the disk a guest is running on' );
    is_deeply( \@deleted, [], 'removing none of it' );

    says( sub { Trog::Bin::Destroy::sweep_backups( 'qemu:///system', undef, 0 ) } );
    is_deeply( \@deleted, [qw{gone.test.bak-qcow2 live.test.bak-qcow2}], 'and the sweep takes the copies, and only the copies' );

    # The other half of that sentence.  One of the two forms went out reading
    # "1 disks were copied aside", which is the sort of thing that makes an
    # operator distrust the rest of what a destructive command says.
    @deleted = ();
    local @Test::Pool::VOLUMES = qw{only.test.bak-qcow2};
    my ($alone) = says( sub { Trog::Bin::Destroy::sweep_backups( 'qemu:///system', undef, 1 ) } );
    like( $alone, qr/One[ ]disk[ ]was/, 'and a single copy is counted in the singular' );
    unlike( $alone, qr/1[ ]disks/, 'rather than agreeing with nothing' );

    # A pool that will not answer is not a pool with nothing in it, and the
    # sweep says so rather than reporting a clean fleet.
    @deleted = ();
    local $Test::Pool::REFUSE = 1;
    my ( $refused, $rc ) = says( sub { Trog::Bin::Destroy::sweep_backups( 'qemu:///system', undef, 0 ) } );
    is( $rc, 1, 'a pool it could not read stops the sweep' );
    like( $refused, qr/what[ ]copies[ ]it[ ]holds/, 'saying which hypervisor would not say' );
    is_deeply( \@deleted, [], 'and nothing is removed on the strength of it' );

    Trog::HV->forget();
};

subtest 'the sweep takes what belongs to no guest, and nothing else' => sub {
    write_config( 'named.test' => 1 );

    # real.example is not .test on purpose, and must not be "corrected" to it:
    # it stands for a domain somebody actually runs, and the assertion at the
    # end of this subtest is that the sweep never looks at one.  Under .test it
    # would be an orphan by definition and the sweep would be right to take it.
    # (.example is reserved by RFC 2606 just as .test is, so it resolves
    # nowhere either.)
    make_path("$data/$_") for qw{orphan.test named.test real.example};

    my ($said) = says( sub { Trog::Bin::Destroy::sweep_orphans( undef, undef, 1 ) } );
    like( $said, qr/orphan\.test/, 'the dry run names the orphan' );
    unlike( $said, qr/named\.test/, 'and not the one the configuration carries' );
    ok( -d "$data/orphan.test", 'and removes nothing' );

    says( sub { Trog::Bin::Destroy::sweep_orphans( undef, undef, 0 ) } );
    ok( !-e "$data/orphan.test", 'the sweep takes the orphan' );
    ok( -d "$data/named.test",   'leaves the one a recipe configuration names' );

    # Every real domain's data lives in the same directory, and the whole reason
    # this is safe to run is that it is only ever looking at .test.
    ok( -d "$data/real.example", 'and does not so much as consider a real domain' );
    File::Path::remove_tree("$data/$_") for qw{named.test real.example};
};

subtest 'the sweep covers the domain directory as well as the data source' => sub {
    my $domains = tempdir( CLEANUP => 1 );
    write_config( 'named.test' => 1 );
    make_path("$data/$_")    for qw{orphan.test live.test};
    make_path("$domains/$_") for qw{orphan.test live.test named.test};

    # A hypervisor to have a domain directory and a list of guests.  Both of the
    # sweep's exclusions come from somewhere real: the configuration above, and
    # this.
    Trog::HV->forget();
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { $domains } );
    $hv->redefine( vmm        => sub { bless {}, 'Test::Libvirt' } );
    local @Test::Libvirt::DOMAINS = ('live.test');

    my ($said) = says( sub { Trog::Bin::Destroy::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    like( $said, qr/\Q$domains\E/, 'the domain directory is one of the places it looks' );

    ok( !-e "$data/orphan.test",    'the orphan goes from the data source' );
    ok( !-e "$domains/orphan.test", 'and from the domain directory' );

    ok( -d "$data/live.test",     'a guest the hypervisor still has is not an orphan' );
    ok( -d "$domains/live.test",  'in either place' );
    ok( -d "$domains/named.test", 'and neither is one the configuration names' );

    Trog::HV->forget();

    # It is only live while this subtest says it is.
    File::Path::remove_tree("$data/live.test");
};

subtest 'a hypervisor that will not say what it has stops the sweep' => sub {
    write_config();
    make_path("$data/orphan.test");

    Trog::HV->forget();
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { tempdir( CLEANUP => 1 ) } );
    $hv->redefine( vmm        => sub { die "connection refused\n" } );

    my ( $said, $rc ) = says( sub { Trog::Bin::Destroy::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    is( $rc, 1, 'the sweep fails rather than carrying on' );
    like( $said, qr/nothing[ ]is[ ]swept/, 'and says so' );

    # The guests it holds are exactly the ones that would look like orphans.
    ok( -d "$data/orphan.test", 'nothing was removed on the strength of a list it could not get' );

    Trog::HV->forget();
    rmdir "$data/orphan.test";
};

subtest 'a sweep with nothing to do says so' => sub {
    write_config( 'named.test' => 1 );

    my ( $said, $rc ) = says( sub { Trog::Bin::Destroy::sweep_orphans( undef, undef, 0 ) } );
    like( $said, qr/belongs[ ]to[ ]a[ ]guest[ ]that[ ]is[ ]gone/, 'says there is nothing' );
    is( $rc, 0, 'and is not a failure' );
};

subtest 'the sweep finds the data source where _global says it' => sub {

    # Where a configuration says it now.  The sweep read only the data recipe's
    # from, and on a configuration saying it here it swept nothing at all.
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_base:\n    _global:\n        data_source: $data\nnamed.test:\n    ntp:\n" );
    Provisioner::Cookbook->forget();
    make_path("$data/$_") for qw{orphan.test named.test};

    says( sub { Trog::Bin::Destroy::sweep_orphans( undef, undef, 0 ) } );
    ok( !-e "$data/orphan.test", 'the orphan goes' );
    ok( -d "$data/named.test",   'and the named one stays' );
    File::Path::remove_tree("$data/named.test");
};

subtest 'with no data source, the domain directories are still swept' => sub {
    my $domains = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$ENV{TROG_PROVISIONER_CONFIG}/recipes.yaml", "_base:\n    ntp:\n" );
    Provisioner::Cookbook->forget();
    make_path("$domains/orphan.test");

    Trog::HV->forget();
    my $hv = Test::MockModule->new('Trog::HV::Libvirt');
    $hv->redefine( domain_dir => sub { $domains } );
    $hv->redefine( vmm        => sub { bless {}, 'Test::Libvirt' } );
    local @Test::Libvirt::DOMAINS = ();

    my ( $said, $rc ) = says( sub { Trog::Bin::Destroy::sweep_orphans( 'qemu:///system', undef, 0 ) } );
    like( $said, qr/only[ ]the[ ]domain[ ]directories[ ]are[ ]swept/, 'saying there is no data source' );
    ok( !-e "$domains/orphan.test", 'and sweeping where guests are built all the same' );
    is( $rc, 0, 'which is not a failure' );

    Trog::HV->forget();
};

# pod2usage exits, so these have to be real runs.
subtest '--orphans takes no domain, and a name of only dots is not one' => sub {
    write_config();

    my $out = q{};
    IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/destroy", qw{--orphans --dryrun} ], \undef, \$out, \$out );
    is( $?, 0, '--orphans runs without one' );
    unlike( $out, qr/No[ ]domain[ ]passed/, 'rather than asking for a domain' );

    IPC::Run3::run3( [ $^X, "$FindBin::Bin/../bin/destroy", qw{--dryrun --purge-data ..} ], \undef, \$out, \$out );
    isnt( $?, 0, 'a domain that is only dots is refused' );
    like( $out, qr/not[ ]a[ ]domain/, 'saying so, before it names anything to remove' );
};

subtest '--purge-data is asked for, and never implied by --purge' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/tenant.test");

    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( find => sub { die "No hypervisor in the fleet has a guest called tenant.test.\n" } );

    my @purged;
    my $bin = Test::MockModule->new( 'Trog::Bin::Destroy', no_auto => 1 );
    $bin->redefine( $_             => sub { 1 } ) for qw{remove_authorized_key remove_runner_key purge_domain_dir release_ip};
    $bin->redefine( purge_data_dir => sub { push @purged, [@_]; 1 } );

    Trog::HV->forget();
    says( sub { Trog::Bin::Destroy::main( '--domaindir', $dir, '--purge', 'tenant.test' ) } );
    is_deeply( \@purged, [], '--purge alone leaves the data directory' );

    says( sub { Trog::Bin::Destroy::main( '--domaindir', $dir, '--purge-data', 'tenant.test' ) } );
    is( scalar @purged, 1,             '--purge-data takes it' );
    is( $purged[0][0],  'tenant.test', 'for that domain' );
    is( $purged[0][1],  undef,         'on this side alone, when no hypervisor held the guest' );

    Trog::HV->forget();
};

subtest 'a guest that will not stop still gives its address back' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/tenant.test");

    # The live failure upstream of step five: annihilate_domain dies when a
    # guest will not stop or will not undefine, and destroy_vm does not catch
    # it.  Unguarded the run ended there, and the address stayed reserved
    # against a domain that had just been taken away.
    Trog::HV->forget();
    my $machine = Trog::HV->new( domain_dir => $dir );

    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( find => sub { return $machine } );

    my $bin = Test::MockModule->new( 'Trog::Bin::Destroy', no_auto => 1 );
    $bin->redefine( destroy_vm => sub { die "Could not undefine tenant.test: still running\n" } );
    $bin->redefine( $_         => sub { 1 } ) for qw{destroy_disks remove_authorized_key remove_runner_key purge_domain_dir};

    my $released;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( held_by => sub { '203.0.113.9' } );
    $pool->redefine( release => sub { $released = $_[0]; 1 } );

    # Caught rather than left to escape: unguarded, main() dies in destroy_vm,
    # the die goes straight through capture, and the file ends on "No plan
    # found in TAP output" -- taking the subtests after it down and saying
    # nothing about the address, which is the thing being asserted.
    my ( $out, $err, $rc );
    my $aborted = exception {
        ( $out, $err, $rc ) = capture { Trog::Bin::Destroy::main( '--domaindir', $dir, 'tenant.test' ) }
    };

    is( $aborted,  undef,         'the run finishes rather than aborting when the guest will not stop' );
    is( $released, 'tenant.test', 'and the address goes back even though it would not stop' );

    # The exact status, not merely "not zero": an aborted run leaves this undef,
    # and undef is already "not zero", so isnt() here would pass in precisely
    # the case this subtest exists to catch.
    is( $rc, 1, 'with a failing status rather than a claim of success' );
    like( $err, qr/Could \s+ not \s+ undefine/, 'having said what went wrong' );
    unlike( $out, qr/Done[.] \s* \z/, 'and not signing off as though nothing had' );

    Trog::HV->forget();
};

subtest 'a domain no hypervisor holds still gives its address back' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/tenant.test");

    # A guest sharing another domain's machine never had a VM of its own, so the
    # fleet has nothing to find.  That used to stop the run before step five --
    # measured on a shared host, where tearing the tenant down left its address
    # reserved against a domain that no longer existed.
    my $fleet = Test::MockModule->new('Trog::Hypervisors');
    $fleet->redefine( find => sub { die "No hypervisor in the fleet has a guest called tenant.test.\n" } );

    my @asked;
    my $bin = Test::MockModule->new( 'Trog::Bin::Destroy', no_auto => 1 );
    $bin->redefine( $_ => sub { 1 } )                        for qw{remove_authorized_key remove_runner_key};
    $bin->redefine( $_ => sub { push( @asked, $_[0] ); 1 } ) for qw{destroy_vm destroy_disks};

    my $released;
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( held_by => sub { '203.0.113.9' } );
    $pool->redefine( release => sub { $released = $_[0]; 1 } );

    Trog::HV->forget();
    my ( $out, $rc ) = capture_stdout { Trog::Bin::Destroy::main( '--domaindir', $dir, 'tenant.test' ) };

    is( $rc, 0, 'the run finishes rather than stopping on the lookup' );

    # Nothing hosts it, so there is no VM and no disk to ask about -- and the
    # machine this falls back to is not a hypervisor on a fleet that keeps them
    # elsewhere, so asking dies on the libvirt socket before the address is back.
    is_deeply( \@asked, [], 'no hypervisor is asked to destroy anything' );
    is( $released, 'tenant.test', 'and the address goes back to the pool' );
    like( $out, qr/only[ ]what[ ]is[ ]on[ ]this[ ]side[ ]goes/, 'saying it is cleaning up this side alone' );

    # This replaces the class-wide hypervisor, which is why the subtest sits last
    # in the file: the ones above it resolve their paths through Trog::HV->new()
    # and do not survive having it swapped out from under them.
    Trog::HV->forget();
};

done_testing;
