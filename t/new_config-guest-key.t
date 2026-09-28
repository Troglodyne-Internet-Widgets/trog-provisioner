#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-guest-key.t - restore_sealed_key in bin/new_config: a domain keeps
the key that the store holds when its domain directory has been purged

=cut

use Test::More;
use Test::MockModule qw{strict};
use Test::NoWarnings qw{had_no_warnings};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();

use FindBin;
use FindBin::libs;

use Provisioner::Utils();
use Provisioner::Cookbook();

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my $store_dir = File::Temp::tempdir( CLEANUP => 1 );
my $stored    = "$store_dir/stored.rsa";
Provisioner::Utils::write_ssh_keypair( $stored, RSA => 2048, 'stored' );
my $stored_public = Provisioner::Utils::ssh_pubkey_from_private($stored);

my $held  = $stored;
my $guest = Test::MockModule->new('Trog::Guest');
$guest->redefine( key_path => sub { my ( undef, undef, $on_disk ) = @_; return -e $on_disk ? $on_disk : $held } );

# What a teardown leaves: the key in the store, and no domain directory.
my $cfg = File::Temp::tempdir( CLEANUP => 1 );
Trog::Provisioner::Config::Generator::restore_sealed_key( 'guest.test', $cfg );

is( File::Slurper::read_binary("$cfg/key.rsa"), File::Slurper::read_binary($stored), 'the private half comes back from the store' );
my ($public) = File::Slurper::read_text("$cfg/key.rsa.pub") =~ m/\A(\S+[ ]\S+)/;
is( $public, $stored_public, 'and the public half is derived from it' );

my $recipe = Provisioner::Cookbook->load('ubuntu')->new( output_dir => $cfg );
my $key    = $recipe->guest_keypair( domain => 'guest.test' );
is( $key->{private}, File::Slurper::read_text($stored), 'so the recipe keeps the key rather than making a new one' );

# A public half that is there is left as it is.
File::Slurper::Temp::write_text( "$cfg/key.rsa.pub", "ssh-rsa AAAAkept guest.test\n" );
Trog::Provisioner::Config::Generator::restore_sealed_key( 'guest.test', $cfg );
is( File::Slurper::read_text("$cfg/key.rsa.pub"), "ssh-rsa AAAAkept guest.test\n", 'a public half on disk is not replaced' );

# A domain that the store has no key for gets nothing, and the recipe makes one.
undef $held;
my $none = File::Temp::tempdir( CLEANUP => 1 );
Trog::Provisioner::Config::Generator::restore_sealed_key( 'new.test', $none );
ok( !-e "$none/key.rsa" && !-e "$none/key.rsa.pub", 'a domain with no key gets no files' );

had_no_warnings();
done_testing();
