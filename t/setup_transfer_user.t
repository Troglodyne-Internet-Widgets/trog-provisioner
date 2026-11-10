#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/setup_transfer_user.t - scripts/setup_transfer_user: what it sets up for the
account that guests fetch as, and when it stops

=head1 DESCRIPTION

The script runs as root, and changes accounts and sshd.  So the commands that
need root are stand-ins first on the PATH, which write each command line to a
log.  The stand-in of install copies, and the stand-in of sshd answers from
the file that the script wrote.

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();
use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/setup_transfer_user";

my %STAND_IN = (
    id => <<'SH',
case "$1" in
-u) echo "${FAKE_UID:-0}" ;;
-gn) [ "$2" = nobody-here ] && exit 1; echo "$2-group" ;;
*) case " $FAKE_USERS " in *" $1 "*) exit 0 ;; esac; exit 1 ;;
esac
SH
    getent  => 'echo "$3:x:1:1::/bogus:${FAKE_SHELL:-/bin/sh}"',
    useradd => 'echo "useradd $*" >>"$FAKE_LOG"',
    usermod => 'echo "usermod $*" >>"$FAKE_LOG"',
    install => <<'SH',
echo "install $*" >>"$FAKE_LOG"
dir=; while [ $# -gt 2 ]; do case "$1" in -d) dir=1; shift ;; -o|-g|-m) shift 2 ;; *) break ;; esac; done
if [ -n "$dir" ]; then mkdir -p "$1"; else cp "$1" "$2"; fi
SH
    sshd => <<'SH',
case "$1" in
-t) exit "${FAKE_SSHD_T:-0}" ;;
-T) if [ -n "${FAKE_OTHER_AKC:-}" ]; then echo "authorizedkeyscommand $FAKE_OTHER_AKC"; else sed -n 's/^ *AuthorizedKeysCommand /authorizedkeyscommand /p' "$TROG_SSHD_CONFIG_D"/*.conf; fi ;;
esac
SH
    systemctl => 'echo "systemctl $*" >>"$FAKE_LOG"',
);

# One run of the script: its exit status, what it said, what the stand-ins
# logged, and the directories that it set up.
sub setup {
    my ( $env, @args ) = @_;

    my $root = tempdir( CLEANUP => 1 );
    mkdir "$root/$_" for qw{bin sshd_config.d};
    foreach my $name ( keys %STAND_IN ) {
        File::Slurper::Temp::write_text( "$root/bin/$name", "#!/bin/sh\n$STAND_IN{$name}" );
        chmod 0755, "$root/bin/$name";
    }

    local %ENV = (
        %ENV,
        PATH               => "$root/bin:$ENV{PATH}",
        FAKE_LOG           => "$root/log",
        FAKE_USERS         => 'agent',
        TROG_LIBEXEC       => "$root/libexec",
        TROG_GUEST_KEYS    => "$root/state/guest-keys",
        TROG_SSHD_CONFIG_D => "$root/sshd_config.d",
        SSHD_PRIVSEP_DIR   => "$root/run-sshd",
        %$env,
    );
    my ( $out, $err );
    IPC::Run3::run3( [ $script, @args ], \undef, \$out, \$err );
    my $log = -e "$root/log" ? File::Slurper::read_text("$root/log") : q{};
    return ( $? >> 8, "$out$err", $log, $root );
}

subtest 'a new transfer account, beside the provisioning account' => sub {
    my ( $rc, $said, $log, $root ) = setup( {}, 'fetcher', 'agent' );
    is( $rc, 0, 'it exits 0' ) or diag $said;

    like( $log, qr/^useradd[ ]--system[ ]--shell[ ]\/bin\/sh[ ]\N*[ ]fetcher$/m, 'it makes the account, with a shell for the command of a key' );
    like( $log, qr/^usermod[ ]-a[ ]-G[ ]agent-group[ ]fetcher$/m,                'in the group of the provisioning account, to read the payload' );

    my @log = split /\n/, $log;
    foreach my $program (qw{rsyncd_sandbox guest_authorized_keys}) {
        is( File::Slurper::read_text("$root/libexec/$program"), File::Slurper::read_text("$FindBin::Bin/../scripts/$program"), "it installs $program" );
        ok( ( grep { index( $_, 'install -o root -g root -m 0755 ' ) == 0 && index( $_, "/$program " ) > 0 } @log ), 'owned by root, and run by everybody' );
    }
    ok( ( grep { $_ eq "install -d -o root -g agent-group -m 2775 $root/state/guest-keys" } @log ), 'the keys go where the provisioning account can write, and everybody read' );
    ok( ( grep { $_ eq 'systemctl try-reload-or-restart ssh' } @log ),                              'and sshd reloads its configuration, if it runs' );
    ok( ( grep { $_ eq 'systemctl reload ssh-fastlane' } @log ),                                    'and so does the fast lane, which the stand-in says runs' );

    is( File::Slurper::read_text("$root/sshd_config.d/50-trog-transfer-fetcher.conf"), <<"CONF", 'which asks the helper, as nobody, for the keys of the transfer account alone' );
# Written by setup_transfer_user of trog-provisioner.  Do not edit by hand.
# The keys of guests, which may run only the sandbox of a fetch.
Match User fetcher
    AuthorizedKeysCommand $root/libexec/guest_authorized_keys $root/state/guest-keys
    AuthorizedKeysCommandUser nobody
CONF
};

subtest 'an account with no shell, which --give-shell gives one' => sub {
    my ( $rc, $said, $log ) = setup( { FAKE_USERS => 'agent fetcher', FAKE_SHELL => '/usr/sbin/nologin' }, qw{--give-shell fetcher agent} );
    is( $rc, 0, 'it exits 0' ) or diag $said;
    ok( ( grep { $_ eq 'usermod -s /bin/sh fetcher' } split /\n/, $log ), 'and gives the account /bin/sh' );

    ( $rc, $said, $log ) = setup( { FAKE_USERS => 'agent fetcher' }, qw{--give-shell fetcher agent} );
    unlike( $log, qr/usermod[ ]-s/, 'but leaves the shell of an account that has one' );
};

subtest 'an account that already provisions and fetches' => sub {
    my ( $rc, $said, $log ) = setup( { FAKE_USERS => 'agent' }, 'agent', 'agent' );
    is( $rc, 0, 'it exits 0' ) or diag $said;
    unlike( $log, qr/^useradd|^usermod/m, 'and changes no account' );
};

subtest 'the provisioning account comes from sudo when it is not named' => sub {
    my ( $rc, $said, $log ) = setup( { SUDO_USER => 'agent' }, 'fetcher' );
    like( $log, qr/^usermod[ ]-a[ ]-G[ ]agent-group[ ]fetcher$/m, 'the account that ran sudo' );

    ( $rc, $said, $log ) = setup( { SUDO_USER => q{}, FAKE_USERS => 'agent fetcher' }, 'fetcher' );
    is( $rc, 0, 'and without sudo it is the transfer account' ) or diag $said;
    unlike( $log, qr/^usermod/m, 'which is in its own group already' );
};

subtest 'and it stops, before sshd reloads, when' => sub {
    my %case = (
        'it is not root'                        => [ { FAKE_UID => 1000, SUDO_USER => q{} },                               qr{as[ ]root:[ ]sudo[ ]\N*[ ]fetcher[ ]agent} ],
        'the transfer account has no shell'     => [ { FAKE_USERS => 'agent fetcher', FAKE_SHELL => '/usr/sbin/nologin' }, qr/usermod[ ]-s[ ]\/bin\/sh[ ]fetcher/ ],
        'sshd refuses its configuration'        => [ { FAKE_SSHD_T => 255 },                                               qr/sshd[ ]refuses/ ],
        'an earlier file names another command' => [ { FAKE_OTHER_AKC => '/bogus/other' },                                 qr/an[ ]earlier[ ]file/ ],
    );
    foreach my $what ( sort keys %case ) {
        my ( $env, $why ) = @{ $case{$what} };
        my ( $rc, $said, $log ) = setup( $env, 'fetcher', 'agent' );
        is( $rc, 1, $what );
        like( $said, $why, 'saying why' );
        unlike( $log, qr/^systemctl/m, 'and sshd is not reloaded' );
    }

    my ( $rc, $said ) = setup( {}, 'fetcher', 'nobody-here' );
    is( $rc, 1, 'or the provisioning account is not there' );
    like( $said, qr/there[ ]is[ ]no[ ]account[ ]nobody-here/, 'saying so' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
