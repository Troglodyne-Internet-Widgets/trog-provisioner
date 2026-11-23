#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/root_access.t - scripts/root_access: report a user who is not an admin
becoming root, and a root login from a host that is not trusted, once each

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::MockModule;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use Capture::Tiny qw{capture capture_stderr};
use File::Which();

use FindBin;

my $script = "$FindBin::Bin/../scripts/root_access";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# The account that runs the test stands in for an admin, because the script
# resolves each admin to the uid of a real account.
my $admin     = scalar getpwuid($<);
my %admin_uid = ( $< => 1 );
my $stranger  = $< + 54_321;

sub session {
    my ( $service, $by ) = @_;
    return "2026-11-19T00:49:42.391607+00:00 host.test.test $service: pam_unix($service:session): session opened for user root(uid=0) by $by";
}

# What sudo logs on the line before the session that runs the command.
sub sudo_command {
    my ( $user, $command ) = @_;
    return "2026-11-19T00:49:42.391000+00:00 host.test.test sudo:     $user : PWD=/bogus ; USER=root ; COMMAND=$command";
}

sub login {
    my ($from) = @_;
    return "2026-11-19T00:49:42.391607+00:00 host.test.test sshd[1234]: Accepted publickey for root from $from port 50486 ssh2: ED25519 SHA256:bogus";
}

subtest 'escalation' => sub {
    ok( Trog::RootAccess::escalation( session( 'sudo', "bogus(uid=$stranger)" ), \%admin_uid ), 'sudo by a user who is not an admin is an escalation' );
    ok( Trog::RootAccess::escalation( session( 'su',   "(uid=$stranger)" ),      \%admin_uid ), 'and so is su with no login name' );
    ok(
        Trog::RootAccess::escalation( "Sep 18 10:00:02 host sudo[3]: pam_unix(sudo:session): session opened for user root by bogusold(uid=$stranger)", \%admin_uid ),
        'in the format that Linux-PAM wrote before 1.4, with a BSD time stamp'
    );
    ok( !Trog::RootAccess::escalation( session( 'sudo', "root(uid=$<)" ),        \%admin_uid ), 'an admin is exempt by uid, whatever login name the line shows' );
    ok( !Trog::RootAccess::escalation( session( 'sudo', 'root(uid=0)' ),         \%admin_uid ), 'root opening a session as root is no escalation' );
    ok( !Trog::RootAccess::escalation( session( 'atd',  'root(uid=1)' ),         \%admin_uid ), 'nor is an at job of root, which atd starts as the daemon user' );
    ok( !Trog::RootAccess::escalation( session( 'cron', "root(uid=$stranger)" ), \%admin_uid ), 'nor a cron job of root' );
    ok(
        !Trog::RootAccess::escalation(
            "2026-11-19T00:49:42+00:00 host.test.test sudo:    bogus : PWD=/bogus ; USER=root ; COMMAND=/usr/bin/grep 'pam_unix(sudo:session): session opened for user root by x(uid=$stranger)' /bogus",
            \%admin_uid
        ),
        'nor a command line that sudo logs, which quotes the text of one'
    );
};

subtest 'allows' => sub {
    ok( Trog::RootAccess::allows( '/bogus/sbin/install-packages',              '/bogus/sbin/install-packages' ),             'a grant of a program alone allows it with no arguments' );
    ok( Trog::RootAccess::allows( '/bogus/sbin/install-packages',              "/bogus/sbin/install-packages git 'a b'" ),   'and with any arguments, as in sudo' );
    ok( !Trog::RootAccess::allows( '/bogus/sbin/install-packages',             '/bogus/sbin/install-packages-other' ),       'but not another program whose name starts the same' );
    ok( Trog::RootAccess::allows( '/usr/bin/uptime ""',                        '/usr/bin/uptime' ),                          'a grant with "" allows the program with no arguments' );
    ok( !Trog::RootAccess::allows( '/usr/bin/uptime ""',                       '/usr/bin/uptime -p' ),                       'and not with any' );
    ok( Trog::RootAccess::allows( '/usr/bin/systemctl restart bogus.service',  '/usr/bin/systemctl restart bogus.service' ), 'a grant with arguments allows exactly that command' );
    ok( !Trog::RootAccess::allows( '/usr/bin/systemctl restart bogus.service', '/usr/bin/systemctl stop bogus.service' ),    'and no other' );
};

subtest 'granted' => sub {
    my %grants = ( $stranger => ['/bogus/sbin/install-packages'] );
    my $sudo   = session( 'sudo', "(uid=$stranger)" );

    my %command_of = ( $stranger => '/bogus/sbin/install-packages git' );
    ok( Trog::RootAccess::granted( $sudo,  \%command_of, \%grants ), 'a sudo session that runs a command of the grant of the user is granted' );
    ok( !Trog::RootAccess::granted( $sudo, \%command_of, \%grants ), 'and the command exempts that one session, not the next one' );

    %command_of = ( $stranger => '/usr/bin/bash' );
    ok( !Trog::RootAccess::granted( $sudo, \%command_of, \%grants ), 'a command that the grant does not name is not granted' );

    %command_of = ( $stranger => '/bogus/sbin/install-packages git' );
    ok( !Trog::RootAccess::granted( session( 'su',   "(uid=$stranger)" ), \%command_of,                             \%grants ), 'nor a session of su after a granted command' );
    ok( !Trog::RootAccess::granted( session( 'sudo', "(uid=$<)" ),        { $< => '/bogus/sbin/install-packages' }, \%grants ), 'nor a user who has no grant' );
};

subtest 'service_grants' => sub {
    plan skip_all => 'no cvtsudoers here, and the grants are what cvtsudoers reads' unless File::Which::which('cvtsudoers');

    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text(
        "$dir/servicesudo-svc",
        join(
            q{}, map { "$_\n" }
              '# Generated by Provisioner::Recipe::servicesudo.',
            'Defaults:svc !mail_badpass, !mail_no_perms',
            'svc ALL=(root) NOPASSWD: /bogus/sbin/install-packages',
            'svc ALL=(root) NOPASSWD: /usr/bin/uptime ""',
            'svc ALL=(root) /bogus/sbin/with-password',
            'svc ALL=(nobody) NOPASSWD: /bogus/sbin/as-another',
            'ghost ALL=(root) NOPASSWD: /bogus/sbin/anything',
        )
    );
    File::Slurper::Temp::write_text( "$dir/admins",              "svc ALL=(root) NOPASSWD: ALL\n" );
    File::Slurper::Temp::write_text( "$dir/servicesudo-garbled", "svc ALL=(root NOPASSWD /bogus\n" );

    no warnings qw{once};
    local $Trog::RootAccess::SUDOERS_DIR = $dir;
    my $mock = Test::MockModule->new( 'Trog::RootAccess', no_auto => 1 );
    $mock->redefine( uid_of => sub { return $_[0] eq 'svc' ? $stranger : undef } );

    my @warned;
    my ( undef, $grants ) = capture_stderr {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        Trog::RootAccess::service_grants();
    };
    is_deeply(
        $grants,
        { $stranger => [ '/bogus/sbin/install-packages', '/usr/bin/uptime ""' ] },
        'each rule of a servicesudo file as root with no password, by the uid of its user, and not a rule with a password, as another user, in another file, or of a user who has no account'
    );
    is( scalar( grep { m/no[ ]grant[ ]is[ ]read[ ]from[ ]\S*servicesudo-garbled/ } @warned ), 1, 'and a file that cvtsudoers cannot read grants nothing, with a warning' ) or diag @warned;
};

subtest 'untrusted_login' => sub {
    my @trusted = qw{127.0.0.0/8 ::1/128 192.0.2.0/24 198.51.100.7 2001:db8::/32};

    ok( Trog::RootAccess::untrusted_login( login('203.0.113.9'),   \@trusted ), 'a root login from outside every trusted network is reported' );
    ok( Trog::RootAccess::untrusted_login( login('198.51.100.8'),  \@trusted ), 'and from the address beside a trusted one' );
    ok( Trog::RootAccess::untrusted_login( login('2001:db9::1'),   \@trusted ), 'and from outside a trusted IPv6 network' );
    ok( !Trog::RootAccess::untrusted_login( login('192.0.2.200'),  \@trusted ), 'a root login from inside a trusted network is not' );
    ok( !Trog::RootAccess::untrusted_login( login('198.51.100.7'), \@trusted ), 'nor from a trusted address' );
    ok( !Trog::RootAccess::untrusted_login( login('127.0.0.1'),    \@trusted ), 'nor from loopback' );
    ok( !Trog::RootAccess::untrusted_login( login('2001:db8::5'),  \@trusted ), 'nor from inside a trusted IPv6 network' );

    ( my $session = login('203.0.113.9') ) =~ s/sshd\[/sshd-session[/;
    ok( Trog::RootAccess::untrusted_login( $session, \@trusted ), 'OpenSSH 9.8 and later log the login as sshd-session' );

    ( my $user = login('203.0.113.9') ) =~ s/for[ ]root/for bogus/;
    ok( !Trog::RootAccess::untrusted_login( $user, \@trusted ), 'a login as another user is not a root login' );
};

subtest 'in_network' => sub {
    ok( Trog::RootAccess::in_network( '10.1.2.3',         '10.0.0.0/8' ),      'an address in an IPv4 network' );
    ok( !Trog::RootAccess::in_network( '11.0.0.0',        '10.0.0.0/8' ),      'the first address past it' );
    ok( Trog::RootAccess::in_network( '10.0.0.1',         '0.0.0.0/0' ),       'every address is in /0' );
    ok( !Trog::RootAccess::in_network( '::ffff:10.0.0.1', '10.0.0.0/8' ),      'an IPv6 address is in no IPv4 network' );
    ok( !Trog::RootAccess::in_network( '10.0.0.1',        '10.0.0.0/33' ),     'no address is in a network with too long a prefix' );
    ok( !Trog::RootAccess::in_network( '10.0.0.1',        'bogus.test.test' ), 'nor in a name' );
    ok( !Trog::RootAccess::in_network( 'bogus',           '0.0.0.0/0' ),       'and a name is in no network' );
};

subtest 'key_sources and authorized_keys_files' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text(
        "$dir/keys.root",
        join(
            q{}, map { "$_\n" }
              'restrict,from="192.0.2.5",command="/bogus ban" ssh-ed25519 AAAA bogus',
            'from="198.51.100.0/24,*.test.test,!192.0.2.66" ssh-ed25519 AAAA bogus',
            'ssh-ed25519 AAAA unpinned',
        )
    );

    my $mock = Test::MockModule->new( 'Trog::RootAccess', no_auto => 1 );
    $mock->redefine( sshd_authorized_keys_file => sub { ( '.ssh/authorized_keys', "$dir/keys.%u", '%h/100%%' ) } );

    my $home = ( getpwnam('root') )[7];
    is_deeply( [ Trog::RootAccess::authorized_keys_files() ], [ "$home/.ssh/authorized_keys", "$dir/keys.root", "$home/100%" ], 'each file is expanded for root, and a relative one is under its home' );
    is_deeply( [ Trog::RootAccess::key_sources() ], [ '192.0.2.5', '198.51.100.0/24' ], 'each from= address or network is trusted, and a pattern or a negation is not' );
};

subtest 'main' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/admin_networks", "192.0.2.0/24\n\n" );

    # The script loads at run time, so the compiler sees each of these once.
    no warnings qw{once};
    local $Trog::RootAccess::STATE_DIR      = $dir;
    local $Trog::RootAccess::AUTHLOG        = "$dir/auth.log";
    local $Trog::RootAccess::ADMIN_NETWORKS = "$dir/admin_networks";

    my $mock = Test::MockModule->new( 'Trog::RootAccess', no_auto => 1 );
    $mock->redefine( authorized_keys_files => sub { () } );
    $mock->redefine( service_grants        => sub { return { $stranger => ['/bogus/sbin/install-packages'] } } );
    $mock->redefine( uid_of                => sub { return $_[0] eq 'svc' ? $stranger : undef } );

    my $run = sub {
        my (@lines) = @_;
        File::Slurper::Temp::write_text( "$dir/auth.log", join( q{}, map { "$_\n" } @lines ) );
        my ( $out, $err, $exit ) = capture { Trog::RootAccess::main($admin) };
        is( $exit, 0, 'it exits clean' ) or diag $err;
        return $out;
    };

    my $escalation = session( 'sudo', "bogus(uid=$stranger)" );
    my $outsider   = login('203.0.113.9');
    my $said       = $run->( $escalation, $outsider, login('192.0.2.7'), session( 'sudo', "root(uid=$<)" ) );
    like( $said, qr/^DANGER:[^\n]*\Q$dir\E\/auth[.]log/, 'new root access is reported, naming the log it read' );
    is_deeply(
        [ grep { !m/^DANGER/ } split( m/\n/, $said ) ],
        [ sort $escalation, $outsider ],
        'with the escalation and the login from outside, and not the login from an admin network or the sudo of the admin'
    );

    is( $run->( $escalation, $outsider ), '', 'what was reported is not reported again' );

    my $by_grant = session( 'sudo', "root(uid=$stranger)" );
    is( $run->( $escalation, $outsider, sudo_command( 'svc', '/bogus/sbin/install-packages git' ), $by_grant ), '', 'a service user who runs a command of its grant is not reported' );

    my $not_granted = $by_grant =~ s/49:42[.]391607/49:43.000000/r;
    is(
        $run->( $escalation, $outsider, sudo_command( 'svc', '/bogus/sbin/install-packages git' ), $by_grant, sudo_command( 'svc', '/usr/bin/bash' ), $not_granted ),
        "DANGER: New root access by an unexpected user or host, investigate $dir/auth.log!\n$not_granted\n",
        'but a command that its grant does not name is'
    );

    my $again = login('203.0.113.10');
    is( $run->( $outsider, $again ), "DANGER: New root access by an unexpected user or host, investigate $dir/auth.log!\n$again\n", 'and a new line is reported alone' );
};

had_no_warnings();
done_testing();
