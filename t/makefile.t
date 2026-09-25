#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/makefile.t - templates/makefile.tt: what the guest makefile does around the
recipes, as bin/new_config renders it

=cut

use Test::More;
use Test::NoWarnings;
use Text::Xslate;
use Text::Xslate::Bridge::TT2;

use FindBin;
use FindBin::libs;

# These patterns quotemeta a literal on purpose: a fixture string this test
# wrote itself, full of dots and slashes that would otherwise need escaping one
# at a time.  The policy is about production code, where a \Q...\E round
# anything but an interpolated value is usually an accident.
## no critic (RegularExpressions::PreventUselessMetacharacterEscapes)

# Rendered the way bin/new_config renders it: TTerse, the TT2 bridge, and its
# one formatter.
my $tt = Text::Xslate->new(
    path     => ["$FindBin::Bin/../templates"],
    syntax   => 'TTerse',
    module   => [qw{Text::Xslate::Bridge::TT2}],
    function => {
        tabinate => Text::Xslate::html_builder(
            sub {
                my $input = shift;
                $input =~ s/^\s*/\t/mg;
                return $input;
            }
        ),
    },
);

my $STATE = '/etc/provisioner/state/guest.test.test';

sub makefile {
    my (%extra) = @_;
    return $tt->render(
        'makefile.tt',
        {
            vars                   => {},
            user                   => 'svc',
            admin_user             => 'admin',
            domain                 => 'guest.test.test',
            install_dir            => '/opt/domains',
            state_dir              => $STATE,
            global_state_dir       => '/etc/provisioner/state',
            script_dir             => '/root/bin',
            modules_ordered        => ["$STATE/perl"],
            fragments              => { perl => "echo perl\n" },
            global_fragments       => {},
            data_fragment          => "echo data\n",
            testdeps               => [],
            testdeps_flags         => [],
            full_aliases           => [],
            packager_invocation    => 'apt-get install -y',
            packager_up_invocation => 'apt-get update',
            %extra,
        }
    );
}

# Where a target comes in all's prerequisites, or undef.
sub position {
    my ( $prereqs, $target ) = @_;
    my ($at) = grep { $prereqs->[$_] eq $target } 0 .. $#$prereqs;
    return $at;
}

# Under make -j, the prerequisites of all no longer run in their order.  The
# order-only prerequisites are what hold it, so each target must name what has
# to finish before it, and none may contradict the order of all.
subtest 'the order of all is stated as edges, so make -j keeps it' => sub {
    my $G  = '/etc/provisioner/state';
    my $mf = makefile(
        modules_ordered  => [ "$G/global_nginx", "$STATE/tcms", "$STATE/perl" ],
        order_only       => { "$STATE/perl" => ["$STATE/tcms"] },
        fragments        => { tcms          => "echo tcms\n", perl => "echo perl\n" },
        global_fragments => { nginx         => "echo nginx\n" },
        ufw_fragment     => "echo ufw\n",
        fetch_hosts      => ['cpan.test.test'],
        cache_ip         => '192.0.2.1',
    );

    my %before;
    while ( $mf =~ m/^(\S+):[ ][|]((?:[ ]\S+)+)$/mg ) {
        $before{$1} = [ split q{ }, $2 ];
    }
    my ($all) = $mf =~ m/^all:([^\n]*)$/m;
    my @all   = split q{ }, $all;

    ok( !exists $before{"$STATE/state"}, 'the first target waits for nothing' );
    is_deeply( $before{"$STATE/sysctl"},          ["$STATE/service_user"],                                                       'each global target waits for the one before it' );
    is_deeply( $before{"$STATE/fetch_via_cache"}, ["$STATE/testdeps"],                                                           'the cache after the last of them' );
    is_deeply( $before{"$STATE/tcms"},            ["$STATE/fetch_via_cache"],                                                    'every recipe after the cache' );
    is_deeply( $before{"$STATE/perl"},            [ "$STATE/fetch_via_cache", "$STATE/tcms" ],                                   'and after the recipes that required it' );
    is_deeply( $before{"$STATE/ufw"},             [ "$STATE/fetch_via_cache", "$G/global_nginx", "$STATE/tcms", "$STATE/perl" ], 'and ufw after every recipe' );

    is( scalar( grep { !exists $before{$_} } @all ), 1, 'every target of all but the first has its order stated' );
    foreach my $target ( sort keys %before ) {
        foreach my $earlier ( @{ $before{$target} } ) {
            cmp_ok( position( \@all, $earlier ), '<', position( \@all, $target ), "$earlier comes before $target in all as well" );
        }
    }

    my $plain = makefile();

    # apt-get update fails at once on the lock of another apt, so make -j runs
    # every apt through scripts/serial_apt, first on its PATH.
    like( $plain, qr{^export[ ]PATH[ ]:=[ ]/root/bin/serial-apt:\$\(PATH\)$}m, 'the serial apt comes first on the PATH' );
    is_deeply( [ $plain =~ m{^\tln[ ]-sf[ ]/root/bin/serial_apt[ ](\S+)$}mg ], [qw{/root/bin/serial-apt/apt-get /root/bin/serial-apt/apt}], 'as apt-get and as apt' );
    is_deeply( [ $plain =~ m{^(\S+/perl):[ ][|][ ](\S+)$}m ],                  [ "$STATE/perl", "$STATE/testdeps" ],                        'without a cache, recipes wait for the last global target' );
};

subtest 'with hosts to fetch through a cache, it points them there and gives them back' => sub {
    my $mf = makefile( cache_ip => '192.0.2.9', fetch_hosts => [qw{codeload.github.com www.cpan.org}] );

    my ($all)   = $mf =~ m/^all:([^\n]*)$/m;
    my @prereqs = split( q{ }, $all // q{} );
    my $at      = position( \@prereqs, "$STATE/fetch_via_cache" );
    ok( defined $at, 'the cache target is one of what all builds' ) or return;
    ok( $at > position( \@prereqs, "$STATE/scripts" ), 'after the script it runs is put in place' );
    ok( $at < position( \@prereqs, "$STATE/perl" ),    'and ahead of every recipe, which is what downloads' );

    my ($target) = $mf =~ m/^\Q$STATE\E\/fetch_via_cache:\n((?:\t[^\n]*\n)+)/m;
    is( $target, "\t/root/bin/fetch_via_cache on 192.0.2.9 fetchcache-ca.crt codeload.github.com www.cpan.org\n", 'pointing each host at the cache, with the authority to trust' );
    unlike( $target // q{}, qr/touch/, 'and never marked done, so a make run again asks the cache again' );

    my ($recipe) = $mf =~ m/^all:[^\n]*\n((?:\t[^\n]*\n)+)/m;
    like( $recipe // q{}, qr{post_install[ ]\|\|[ ]touch[ ]/root/\.postrun_failed\n\t/root/bin/fetch_via_cache[ ]off\n}, 'every host given back once the deferred work is done' );    ## no critic (RegularExpressions::ProhibitComplexRegexes)
    ok( index( $recipe // q{}, 'fetch_via_cache off' ) < index( $recipe // q{}, "$STATE/test" ), 'and before the tests, which ask about the guest as it will be left' );
};

subtest 'without, there is nothing about a cache at all' => sub {
    unlike( makefile( cache_ip => q{}, fetch_hosts => undef ), qr/fetch_via_cache/, 'no cache' );
    unlike( makefile(),                                        qr/fetch_via_cache/, 'nor when nothing was said about one' );
};

subtest 'testdeps: installed with the flags bin/new_config chose for them' => sub {
    my ($target) = makefile( testdeps => [qw{Test::More Test::Deep}], testdeps_flags => ['--mirror-only'] ) =~ m/^\Q$STATE\E\/testdeps:\n((?:\t[^\n]*\n)+)/m;
    like( $target // q{}, qr/^\tcpanm[ ]--mirror-only[ ]Test::More[ ]Test::Deep$/m, 'each flag ahead of the modules' ) or diag $target;

    ($target) = makefile( testdeps => ['Test::More@1.302'], testdeps_flags => [] ) =~ m/^\Q$STATE\E\/testdeps:\n((?:\t[^\n]*\n)+)/m;
    like( $target // q{}, qr/^\tcpanm[ ]Test::More\@1\.302$/m, 'and none when none were chosen' ) or diag $target;

    unlike( makefile(), qr/^\tcpanm/m, 'and no cpanm at all with nothing to install' );
};

# Recipe lines ran under dash until recently, and dash's echo expands \n where
# bash's does not -- so sendmail's config is written with printf, and the shell
# is named rather than inherited from whatever make would pick.
subtest 'the makefile names its shell, and writes sendmail config without relying on one' => sub {
    my $mf = makefile();

    like( $mf, qr{^SHELL[ ]:=[ ]/bin/bash$}m, 'recipe lines run under bash' );

    my ($sendmail) = $mf =~ m/^\Q$STATE\E\/sendmail:\n((?:\t[^\n]*\n)+)/m;
    like( $sendmail   // q{}, qr/\Qprintf '%s\E/, 'starttls is appended with printf' ) or diag $sendmail;
    unlike( $sendmail // q{}, qr/\Qecho "include\E/, 'and not with an echo only dash expands' );
};

# Debian generates /etc/mail/tls/* in sendmailconfig, which its postinst only
# reaches by asking a question a noninteractive install never answers.  Turning
# starttls on without it left sendmail presenting a certificate nothing had
# made, which every guest logged on the restart the postrun queues.
subtest 'the sendmail target makes a certificate before it turns starttls on' => sub {
    my ($sendmail) = makefile() =~ m/^\Q$STATE\E\/sendmail:\n((?:\t[^\n]*\n)+)/m;

    like( $sendmail // q{}, qr/update_tls/, 'the certificate is generated' ) or diag $sendmail;

    # Order, not just presence: the include is what asks sendmail for a
    # certificate, so generating one afterwards would still leave the first
    # start without.
    my $made = index( $sendmail // q{}, 'update_tls' );
    my $used = index( $sendmail // q{}, 'starttls.m4' );
    ok( $made > -1 && $used > $made, 'before the include that asks it to present one' )
      or diag "update_tls at $made, starttls.m4 at $used";

    # The config update_tls writes caps emailAddress at 40 and asks for
    # admin@<fqdn>, so a name over 34 characters is refused -- and openssl's
    # complaint is discarded, leaving no certificate and nothing said about it.
    my $widened = index( $sendmail  // q{}, 'emailAddress_max' );
    my $again   = rindex( $sendmail // q{}, 'update_tls' );
    ok( $widened > $made,  'the address cap is widened' ) or diag $sendmail;
    ok( $again > $widened, 'and the certificate retried once it is' )
      or diag "widened at $widened, last update_tls at $again";
};

Test::NoWarnings::had_no_warnings();

done_testing;
