#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-IPPool-Remote.t - bin/ippool on the hypervisor that keeps the database: the kit, and the call

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::NoWarnings qw{had_no_warnings};
use Test::MockModule qw{strict};
use File::Copy();
use File::Path();
use File::Slurper();
use File::Slurper::Temp();
use File::Temp();
use IPC::Run3();

use FindBin::libs;
use Trog::SQLite();

use_ok('Provisioner::IPPool::Remote');

{
    # A hypervisor reached over ssh, played here: its home is a directory of
    # its own, and each command runs there, as ssh runs it in the home of the
    # login user.  The perl is this one, which has DBD::SQLite.
    package FakeRemote;
    sub new ( $class, %opts ) { return bless { home => File::Temp::tempdir( CLEANUP => 1 ), ran => [], put => [], %opts }, $class }
    sub name ($)              { return 'hv1' }
    sub describe ($)          { return 'the hypervisor at qemu+ssh://hv1.test/system' }
    sub ip_perl ($)           { return $^X }
    sub is_local ($)          { return 0 }

    sub capture_with_input ( $self, $input, @argv ) {
        die $self->{unreachable} if $self->{unreachable};
        push @{ $self->{ran} }, [@argv];
        IPC::Run3::run3( [ 'sh', '-c', 'cd "$0" && exec "$@"', $self->{home}, @argv ], \$input, \my $out, \my $err );
        return ( ( grep { $_ eq '--db' } @argv ) ? $self->{garbled} // $out : $out, $err );
    }
    sub capture_cmd ( $self, @argv ) { return ( $self->capture_with_input( q{}, @argv ) )[0] }

    sub mkpath ( $self, @paths ) {
        File::Path::make_path( map { "$self->{home}/$_" } @paths );
        return 1;
    }

    sub put_file ( $self, $local, $remote ) {
        push @{ $self->{put} }, $remote;
        return File::Copy::copy( $local, "$self->{home}/$remote" );
    }

    sub write_text ( $self, $path, $content ) {
        File::Slurper::Temp::write_text( "$self->{home}/$path", $content );
        return 1;
    }
}

subtest 'kit_files and kit_hash: what the far side needs, and a hash that changes with it' => sub {
    my %files = Provisioner::IPPool::Remote::kit_files();
    is_deeply(
        [ grep { !m{\Aschema/ips[.]v\d+[.]update[.]sql\z} } sort keys %files ],
        [qw{bin/ippool lib/Provisioner/IPPool/DB.pm lib/Sub/Retry.pm lib/Trog/SQLite.pm schema/ips.sql}],
        'the script, the module with the SQL, what it loads that a hypervisor lacks, and the schema'
    );
    ok( ( grep { m{\Aschema/ips[.]v3[.]update[.]sql\z} } keys %files ), 'with each update of the schema' );
    ok( !( grep { !-e $files{$_} } keys %files ),                       'and each is a file of this checkout or this perl' );

    my $hash = Provisioner::IPPool::Remote::kit_hash(%files);
    like( $hash, qr/\A[[:xdigit:]]{64}\z/, 'the hash is a SHA-256' );
    is( Provisioner::IPPool::Remote::kit_hash(%files), $hash, 'and the same kit has the same hash' );

    my $copy = File::Temp->new;
    print {$copy} File::Slurper::read_binary( $files{'bin/ippool'} ) . "\n# changed\n";
    close $copy or die "Could not close $copy: $!";
    isnt( Provisioner::IPPool::Remote::kit_hash( %files, 'bin/ippool' => "$copy" ), $hash, 'a change to a file changes it' );
};

subtest 'ensure_kit: put there once, in a directory named by its hash' => sub {
    Provisioner::IPPool::Remote::forget();
    my $hv    = FakeRemote->new;
    my %files = Provisioner::IPPool::Remote::kit_files();
    my $hash  = Provisioner::IPPool::Remote::kit_hash(%files);

    my $dir = Provisioner::IPPool::Remote::ensure_kit($hv);
    is( $dir,                                                   "$Provisioner::IPPool::Remote::KIT_BASE/$hash", 'the directory is named by the hash' );
    is( scalar @{ $hv->{put} },                                 scalar keys %files,                             'each file went' );
    is( File::Slurper::read_text("$hv->{home}/$dir/.complete"), "$hash\n",                                      'and the copy says which kit it is, last' );
    ok( !( grep { m{[.]part[.]} } glob("$hv->{home}/$Provisioner::IPPool::Remote::KIT_BASE/*") ), 'and the copy that it was put together in is gone' );

    @{ $hv->{ran} } = ();
    Provisioner::IPPool::Remote::ensure_kit($hv);
    is_deeply( $hv->{ran}, [], 'the same process does not ask again' );

    Provisioner::IPPool::Remote::forget();
    @{ $hv->{put} } = ();
    Provisioner::IPPool::Remote::ensure_kit($hv);
    is_deeply( $hv->{put}, [], 'another process asks, and puts nothing, because the hypervisor has that kit' );

    # A runner on another checkout: its kit has another hash, and so another
    # directory, and the first stays as it is, for an operation that runs it.
    Provisioner::IPPool::Remote::forget();
    my $copy = File::Temp->new;
    print {$copy} File::Slurper::read_binary( $files{'bin/ippool'} ) . "\n# another checkout\n";
    close $copy or die "Could not close $copy: $!";
    my $mock = Test::MockModule->new('Provisioner::IPPool::Remote');
    $mock->redefine( kit_files => sub { return ( %files, 'bin/ippool' => "$copy" ) } );
    my $other = Provisioner::IPPool::Remote::ensure_kit($hv);
    isnt( $other, $dir, 'another kit goes into a directory of its own' );
    is( File::Slurper::read_text("$hv->{home}/$dir/bin/ippool"), File::Slurper::read_text( $files{'bin/ippool'} ), 'and the kit that was there is untouched' );
};

subtest 'ensure_kit: a copy that says another hash is refused' => sub {
    Provisioner::IPPool::Remote::forget();
    my $hv   = FakeRemote->new;
    my $hash = Provisioner::IPPool::Remote::kit_hash( Provisioner::IPPool::Remote::kit_files() );
    my $dir  = "$hv->{home}/$Provisioner::IPPool::Remote::KIT_BASE/$hash";
    File::Path::make_path($dir);
    File::Slurper::Temp::write_text( "$dir/.complete", "somethingelse\n" );
    File::Slurper::Temp::write_text( "$dir/keep",      "x\n" );

    like( exception { Provisioner::IPPool::Remote::ensure_kit($hv) }, qr/says[ ]it[ ]is[ ]'somethingelse'/, 'it says which directory to remove' );
    ok( -e "$dir/keep", 'and does not remove it itself' );
};

subtest 'call: the operation runs there, in the kit, and its answer comes back' => sub {
    Provisioner::IPPool::Remote::forget();
    Trog::SQLite::forget();
    my $hv = FakeRemote->new;

    like( exception { Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'taken', {} ) }, qr/no[ ]address[ ]database[ ]at[ ]ips[.]db/, 'a database that is not there is refused there' );
    is( Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'init', {} ), "$hv->{home}/ips.db", 'init makes it, on the hypervisor' );

    my %assign = ( domain => 'a.test.test', bin => 'guests', nic => 'br0', main => 1, guest => 1, candidates => [qw{192.0.2.10 192.0.2.11}] );
    is( Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'assign', \%assign ),                             '192.0.2.10', 'an assign runs there' );
    is( Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'assign', { %assign, domain => 'b.test.test' } ), '192.0.2.11', 'and the next sees what it wrote' );
    like( exception { Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'assign', { %assign, domain => 'c.test.test' } ) }, qr/\AIP[ ]pool[ ]exhausted/, 'and its refusal comes back as it was said' );

    my $check = Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'check', {} );
    my $kits  = quotemeta "$hv->{home}/$Provisioner::IPPool::Remote::KIT_BASE/";
    like( $check->{sqlite_module}, qr{\A$kits[[:xdigit:]]{64}/lib/Trog/SQLite[.]pm\z}, 'Trog::SQLite comes from the kit, not from the hypervisor' );

    my ($ran) = grep { $_->[1] =~ m/\A-I/ } @{ $hv->{ran} };
    is_deeply( [ @{$ran}[ 0, 3, 4 ] ], [ $^X, '--db', 'ips.db' ], 'with the perl of the hypervisor, and the database named' );
    ok( !( grep { m/192[.]0[.]2/ } @$ran ), 'and the arguments on standard input, not on the command line' );
};

subtest 'call: a hypervisor that does not answer is named, and nothing is guessed' => sub {
    Provisioner::IPPool::Remote::forget();
    my $hv = FakeRemote->new( unreachable => "Could not ssh to the hypervisor at qemu+ssh://hv1.test/system: no route\n" );
    like( exception { Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'taken', {} ) }, qr/\ACould[ ]not[ ]ask[ ]hv1[ ].*no[ ]route/, 'one that cannot be reached' );

    Provisioner::IPPool::Remote::forget();
    $hv = FakeRemote->new( garbled => "perl: warning: Setting locale failed.\n" );
    like( exception { Provisioner::IPPool::Remote::call( $hv, 'ips.db', 'taken', {} ) }, qr/\Ahv1[ ]did[ ]not[ ]answer[ ]the[ ]taken[ ]of[ ]bin\/ippool/, 'and one that does not answer in JSON' );
};

had_no_warnings();
done_testing();
