#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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
            packages               => [],
            testdeps               => [],
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

subtest 'with hosts to fetch through a cache, it points them there and gives them back' => sub {
    my $mf = makefile( cache_ip => '192.168.1.9', fetch_hosts => [qw{codeload.github.com www.cpan.org}] );

    my ($all)   = $mf =~ m/^all:([^\n]*)$/m;
    my @prereqs = split( q{ }, $all // q{} );
    my $at      = position( \@prereqs, "$STATE/fetch_via_cache" );
    ok( defined $at, 'the cache target is one of what all builds' ) or return;
    ok( $at > position( \@prereqs, "$STATE/scripts" ), 'after the script it runs is put in place' );
    ok( $at < position( \@prereqs, "$STATE/perl" ),    'and ahead of every recipe, which is what downloads' );

    my ($target) = $mf =~ m/^\Q$STATE\E\/fetch_via_cache:\n((?:\t[^\n]*\n)+)/m;
    is( $target, "\t/root/bin/fetch_via_cache on 192.168.1.9 fetchcache-ca.crt codeload.github.com www.cpan.org\n", 'pointing each host at the cache, with the authority to trust' );
    unlike( $target // q{}, qr/touch/, 'and never marked done, so a make run again asks the cache again' );

    my ($recipe) = $mf =~ m/^all:[^\n]*\n((?:\t[^\n]*\n)+)/m;
    like( $recipe // q{}, qr{post_install \|\| touch /root/\.postrun_failed\n\t/root/bin/fetch_via_cache off\n}, 'every host given back once the deferred work is done' );
    ok( index( $recipe // q{}, 'fetch_via_cache off' ) < index( $recipe // q{}, "$STATE/test" ), 'and before the tests, which ask about the guest as it will be left' );
};

subtest 'without, there is nothing about a cache at all' => sub {
    unlike( makefile( cache_ip => q{}, fetch_hosts => undef ), qr/fetch_via_cache/, 'no cache' );
    unlike( makefile(),                                        qr/fetch_via_cache/, 'nor when nothing was said about one' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
