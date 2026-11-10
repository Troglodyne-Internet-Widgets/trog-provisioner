#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Trog-Local.t - Trog::Local: this machine, and which of its addresses a guest can reach

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper::Temp();

use FindBin::libs;

use_ok('Trog::Local') or BAIL_OUT('Trog::Local does not load; the install is incomplete');

subtest 'it is this machine, and says so' => sub {
    my $this_machine = Trog::Local->new();

    ok( $this_machine->is_local, 'this machine is local, which is the whole point of the class' );
    is( $this_machine->describe, 'this machine', 'and is called that in an error' );

    # Inherited from Trog::Machine, whose local branches answer without opening
    # a connection.  They are there rather than on Trog::HV because they
    # describe whoever holds a guest's payload, and that is this machine.
    is( $this_machine->transfer_user,   scalar getpwuid($<),               'the transfer user is whoever is running this' );
    is( $this_machine->authorized_keys, "$ENV{HOME}/.ssh/authorized_keys", 'and it is their own authorized_keys' );
};

subtest 'there is only one machine we are running on' => sub {
    Trog::Local->forget();

    my $first = Trog::Local->new();
    is( Trog::Local->new(), $first, 'asking twice gets the same one' );

    Trog::Local->forget();
    isnt( Trog::Local->new(), $first, 'and forgetting is how a test gets a fresh one' );
};

# A guest is fetched from over one of our addresses and administered over
# another, and which is which depends on whether its hypervisor is us.  Taking
# only the first left the other one counted by the guest's rate limit.
subtest 'every address of ours that reaches the guest, not just the first' => sub {
    my $this_machine = Trog::Local->new();

    my @all = $this_machine->transfer_ips( '127.0.0.1', '127.0.0.2' );
    is_deeply( \@all, ['127.0.0.1'], 'two peers down one interface are one address of ours, not two' );

    is_deeply(
        [ $this_machine->transfer_ips( 'not an address', '127.0.0.1' ) ],
        ['127.0.0.1'],
        'a peer that routes nowhere drops out rather than ending the list'
    );

    is_deeply( [ $this_machine->transfer_ips('not an address') ], [], 'and nothing that routes is an empty list' );

    like(
        exception { $this_machine->transfer_ips() },
        qr/has[ ]to[ ]be[ ]given/,
        'asking without saying which addresses is an error rather than a guess'
    );

    # The single-value form is what the payload rsync is told, because the
    # template names one address.
    is( $this_machine->transfer_ip( 'not an address', '127.0.0.1' ), '127.0.0.1', 'transfer_ip is the first of them' );
    is( $this_machine->transfer_ip('not an address'),                undef,       'and undef when there are none' );
};

subtest 'which of our addresses a guest would reach us at' => sub {
    my $this_machine = Trog::Local->new();

    # Loopback rather than anything real: every machine this could run on
    # answers the same, and the answer is not a guess about the network the
    # test happens to be on.
    is( $this_machine->transfer_ip('127.0.0.1'), '127.0.0.1', 'the source address the routing table would use' );

    # A guest has more than one address on more than one network, and which of
    # them we share with it is not knowable from here.  So they are tried in
    # order, and one that goes nowhere is skipped rather than being the answer.
    is( $this_machine->transfer_ip( 'not an address', '127.0.0.1' ), '127.0.0.1', 'the first that routes decides' );

    # A domain's configured address is written as a cidr, and a network is not
    # something to connect to.
    is( $this_machine->transfer_ip('127.0.0.1/8'), '127.0.0.1', 'a cidr is taken as the address in it' );

    like(
        exception { $this_machine->transfer_ip() },
        qr/has[ ]to[ ]be[ ]given/,
        'asking without saying which addresses is an error rather than a guess'
    );

    is( $this_machine->transfer_ip('not an address'), undef, 'and nothing that routes is no answer' );
};

subtest 'whether bubblewrap can make the sandbox of a fetch here' => sub {
    my $which = Test::MockModule->new('File::Which');
    my $dir   = tempdir( CLEANUP => 1 );

    # A bwrap that answers as the real one does, from a file this test writes.
    my $bwrap = sub ($script) {
        File::Slurper::Temp::write_text( "$dir/bwrap", "#!/bin/sh\n$script\n" );
        chmod 0755, "$dir/bwrap";
        Trog::Local->forget();
        return Trog::Local->new();
    };

    $which->redefine( which => sub { undef } );
    Trog::Local->forget();
    is( Trog::Local->new()->sandbox_error, 'bwrap is not installed', 'no bwrap at all' );

    $which->redefine( which => sub { "$dir/bwrap" } );
    my $this_machine = $bwrap->('echo "bwrap: setting up uid map: Permission denied" >&2; exit 1');
    is( $this_machine->sandbox_error, 'bwrap could not make a sandbox: bwrap: setting up uid map: Permission denied', 'a bwrap that the system refuses, with what it said' );

    $bwrap->('exit 0');
    is( $this_machine->sandbox_error,      'bwrap could not make a sandbox: bwrap: setting up uid map: Permission denied', 'the object keeps the answer' );
    is( Trog::Local->new()->sandbox_error, undef,                                                                          'and a new one asks again, and a bwrap that works is no error' );

    $bwrap->('[ "$*" = "--unshare-all --die-with-parent --ro-bind / / true" ] || exit 1');
    is( Trog::Local->new()->sandbox_error, undef, 'it asks for the namespaces of rsyncd_sandbox, and runs nothing in them' );

    Trog::Local->forget();
};

subtest 'the sandbox program, which root must own so that the account that sshd runs it as cannot change it' => sub {
    my $local        = Test::MockModule->new('Trog::Local');
    my $this_machine = Trog::Local->new();

    {
        local $Trog::Utils::LIBEXEC = tempdir( CLEANUP => 1 );
        is( $this_machine->sandbox_program, "$Trog::Utils::LIBEXEC/rsyncd_sandbox", 'it is rsyncd_sandbox in LIBEXEC' );
        like( $this_machine->sandbox_program_error, qr/is[ ]not[ ]there/, 'not installed' );

        File::Slurper::Temp::write_text( $this_machine->sandbox_program, "#!/bin/sh\n" );
        chmod 0755, $this_machine->sandbox_program;
        like( $this_machine->sandbox_program_error, qr/not[ ]owned[ ]by[ ]root/, 'installed by somebody else than root' ) if $> != 0;
    }

    # Files that root owns on every machine that runs this.
    my %case = (
        '/bin/sh'     => undef,
        '/etc/passwd' => qr/cannot[ ]be[ ]run/,
        '/etc'        => qr/not[ ]a[ ]file/,
    );
    foreach my $path ( sort keys %case ) {
        $local->redefine( sandbox_program => sub { $path } );
        my $why = $this_machine->sandbox_program_error;
        if ( defined $case{$path} ) { like( $why, $case{$path}, "$path is refused" ) }
        else                        { is( $why, undef, "$path, which root owns and everybody runs, is taken" ) }
    }
};

subtest 'the key of a guest is a file of its own, which sshd can read' => sub {
    local $Trog::Utils::GUEST_KEYS = tempdir( CLEANUP => 1 );
    my $this_machine = Trog::Local->new();

    is( $this_machine->guest_keys_error, undef, 'a directory that this account can write' );

    is( $this_machine->authorize_guest_key( 'vm.test.test', '/bogus/domains/vm.test.test', 'ssh-rsa AAAA vm' ), 1, 'is written' );
    my $file = "$Trog::Utils::GUEST_KEYS/vm.test.test";
    is( File::Slurper::read_text($file), "/bogus/domains/vm.test.test\nssh-rsa AAAA vm\n", 'with the domain directory, and then the key' );
    is( ( stat $file )[2] & oct('0777'), oct('0644'),                                      'and everybody can read it, because sshd reads it as nobody' );

    like( exception { $this_machine->authorize_guest_key( '../escape',    '/bogus/d',              'ssh-rsa AAAA' ) }, qr/not[ ]a[ ]domain[ ]name/,          'a name that is not a domain is refused' );
    like( exception { $this_machine->authorize_guest_key( 'vm.test.test', '/bogus/d",command="sh', 'ssh-rsa AAAA' ) }, qr/must[ ]be[ ]an[ ]absolute[ ]path/, 'and so is a directory that a key line cannot hold' );

    is( $this_machine->revoke_guest_key('vm.test.test'), 1, 'revoking it' );
    ok( !-e $file, 'removes it' );
    is( $this_machine->revoke_guest_key('vm.test.test'), 0, 'and a key that is not there is nothing to revoke' );
    like( exception { $this_machine->revoke_guest_key('../escape') }, qr/not[ ]a[ ]domain[ ]name/, 'and a name that is not a domain names nothing to remove' );

    local $Trog::Utils::GUEST_KEYS = '/bogus/no/such/dir';
    like( $this_machine->guest_keys_error, qr/is[ ]not[ ]there/, 'a directory that is not there' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
