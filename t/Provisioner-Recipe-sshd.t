#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-sshd.t - the host key of every guest comes from the secret
store, and a relay keeps the key that it had

=cut

use Test::More;
use Test::NoWarnings;
use Test::MockModule qw{strict};

use FindBin::libs;

use File::Temp();
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use Provisioner::Cookbook();
use Provisioner::Utils();
use Trog::Secrets();

my $sshd = Provisioner::Cookbook->load('sshd');

my $HOST_KEY = '/etc/ssh/ssh_host_ed25519_key';

# A host with one tenant, and a guest of its own.
my $cookbook = Test::MockModule->new('Provisioner::Cookbook');
$cookbook->redefine( configuration => sub { return { _shared => { 'host.test.test' => ['tenant.test.test'] } } } );

subtest 'every distribution requires it' => sub {
    my %required = Provisioner::Cookbook->load('ubuntu')->new( template_dirs => [], output_dir => '/bogus' )->required_recipes();
    ok( exists $required{sshd}, 'so every guest has it, and no configuration names it' );
    is_deeply( { $required{sshd}->() }, {}, 'with nothing to configure' );
};

subtest 'the key belongs to the machine' => sub {
    is( $sshd->host_key_ref('alone.test.test'),  'secret:ssh/alone.test.test-host-key/password', 'a guest of its own has its own entry' );
    is( $sshd->host_key_ref('tenant.test.test'), $sshd->host_key_ref('host.test.test'),          'and a tenant names the entry of its host, whose sshd it shares' );
};

subtest 'bin/provision places it before the makefile runs' => sub {
    my %secrets = $sshd->guest_secrets( '/bogus', 'alone.test.test' );
    is_deeply( [ keys %secrets ], [$HOST_KEY], 'the ed25519 host key, and nothing else' );
    is( $secrets{$HOST_KEY}{ref},   'secret:ssh/alone.test.test-host-key/password', 'from the entry of the machine' );
    is( $secrets{$HOST_KEY}{mode},  '0600',                                         'readable by root only' );
    is( $secrets{$HOST_KEY}{owner}, 'root:root',                                    'and owned by root' );
};

subtest 'a new guest gets a new ed25519 key' => sub {
    my %secrets = $sshd->guest_secrets( '/bogus', 'alone.test.test' );
    my $key     = $secrets{$HOST_KEY}{generate}->( sub { return undef } );

    my $file = File::Temp::tempdir( CLEANUP => 1 ) . '/key';
    File::Slurper::Temp::write_binary( $file, "$key\n" );
    like( Provisioner::Utils::ssh_pubkey_from_private($file), qr/\Assh-ed25519[ ]/, 'with no passphrase, which sshd can load at boot' );
};

# The store, not a mock of it, because the point is what a real store answers
# on the first build after the move.
subtest 'a relay keeps the key that the guests behind it pinned' => sub {
    my $file = File::Temp::tempdir( CLEANUP => 1 ) . '/secrets.kdbx';
    Trog::Secrets->create( $file, 'throwaway', 'secret:relay/relay.test.test-ssh-host-key/password' => 'the key of the relay' );

    my %secrets = $sshd->guest_secrets( '/bogus', 'relay.test.test' );
    my %held    = Trog::Secrets->remember( $file, 'throwaway', $secrets{$HOST_KEY}{ref} => $secrets{$HOST_KEY}{generate} );
    is( $held{'secret:ssh/relay.test.test-host-key/password'}, 'the key of the relay', 'the entry of the machine takes over the key of the relay' );

    my %read = Trog::Secrets->lookup( $file, 'throwaway', probe => 'secret:ssh/relay.test.test-host-key/password' );
    is( $read{probe}, 'the key of the relay', 'and keeps it, so every later build reads it from there' );
};

# Ask sshd, because a HostKey line that sshd reads differently would offer the
# keys of cloud-init beside it, and the file would still look right.
subtest 'sshd offers the placed key and no other' => sub {
    plan skip_all => 'needs RELEASE_TESTING' unless $ENV{RELEASE_TESTING};

    # -G and not -T, because -T loads the keys, which only root can read.
    my $ask = sub ($config) {
        my $said;
        eval { IPC::Run3::run3( [ qw{/usr/sbin/sshd -G -f}, $config ], \undef, \$said, \$said ); 1 } or return;
        return $said;
    };
    plan skip_all => 'needs an sshd to ask' unless defined $ask->('/dev/null');

    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$dir/sshd_config.d" or die "mkdir: $!";
    my $recipe = $sshd->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );
    my ($dropin) = $recipe->generate_files( $dir, domain => 'alone.test.test' );

    # As the sshd_config of Ubuntu has it: the drop-ins first, and no HostKey.
    my $hostkeys = sub (@include) {
        File::Slurper::Temp::write_text( "$dir/sshd_config", join( q{}, map { "Include $_\n" } @include ) );
        my $said = $ask->("$dir/sshd_config") // q{};
        return [ $said =~ m/^hostkey[ ](\S+)$/mg ], $said;
    };

    my ( $without, $said ) = $hostkeys->();
    cmp_ok( scalar @$without, '>', 1, 'with no HostKey line, sshd loads every kind of key that cloud-init makes' ) or diag $said;

    File::Slurper::Temp::write_text( "$dir/sshd_config.d/10-host-key.conf", File::Slurper::read_text("$dir/$dropin") );
    my ( $with, $told ) = $hostkeys->("$dir/sshd_config.d/*.conf");
    is_deeply( $with, [$HOST_KEY], 'and with the drop-in, only the key from the store' ) or diag $told;
};

Test::NoWarnings::had_no_warnings();

done_testing;
