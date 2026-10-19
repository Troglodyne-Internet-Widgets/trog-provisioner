#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/new_config-rsyncd.t - what the key of a guest can fetch from this machine,
asked of rsync itself with the configuration that bin/new_config writes

=cut

use FindBin;
use FindBin::libs;

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Path  qw{make_path};
use File::Slurper::Temp();
use Path::Tiny();
use IPC::Run3();

require_ok("$FindBin::Bin/../bin/new_config") or die "could not require SUT: $@";

my $root = tempdir( CLEANUP => 1 );
my $host = "$root/domains/host.test";

# What a domain directory and a data directory hold.  The domain directory has
# files that no guest may fetch, beside the payload that it must.
my %files = (
    "$host/data.tar.gz"                     => 'the payload of host.test',
    "$host/key.rsa"                         => 'the private key of host.test',
    "$host/guest-secrets.yaml"              => 'where the secrets come from',
    "$root/domains/tenant.test/data.tar.gz" => 'the payload of tenant.test',
    "$root/data/host.test/served"           => 'the data of host.test',
    "$root/data/other.test/secret"          => 'the data of another domain',
    "$root/skel/.bashrc"                    => 'the dotfiles of the admin',
);
foreach my $path ( keys %files ) {
    make_path( $path =~ s{/[^/]+\z}{}r );
    File::Slurper::Temp::write_text( $path, $files{$path} );
}
symlink( "$root/data/other.test/secret", "$root/data/host.test/escape" ) or die "symlink: $!";

Trog::Provisioner::Config::Generator::write_rsyncd_conf( $host, 'host.test', payload => $host, data => "$root/data/host.test", skel => "$root/skel" );
Trog::Provisioner::Config::Generator::write_rsyncd_conf( $host, 'tenant.test', payload => "$root/domains/tenant.test", data => "$root/data/tenant.test" );

# What sshd runs for the key, whatever the client asked for: the forced
# command of bin/provision.  rsync hands its remote shell the host and the
# command, and this ignores both, as sshd does.
my $rsh = "$root/forced";
File::Slurper::Temp::write_text( $rsh, "#!/bin/sh\nexec rsync --server --daemon --config=$host/rsyncd.conf .\n" );
chmod 0755, $rsh;

# Fetches $what into a new directory, as the guest does.  Returns the exit
# status of rsync, what it said, and what arrived, by path to content, with a
# symlink as "-> target".
sub fetch ( $what, @options ) {
    my $into = tempdir( CLEANUP => 1 );
    my ( $out, $err );
    IPC::Run3::run3( [ qw{rsync -r -l}, "--rsh=$rsh", @options, "transfer\@host.test::$what", "$into/" ], \undef, \$out, \$err );
    my $status = $? >> 8;

    my %got;
    Path::Tiny::path($into)->visit(
        sub ( $path, $ ) {
            my $rel = $path->relative($into)->stringify;
            if    ( -l $path )       { $got{$rel} = '-> ' . readlink($path) }
            elsif ( $path->is_file ) { $got{$rel} = $path->slurp_utf8 }
        },
        { recurse => 1 }
    );
    return ( $status, $err, \%got );
}

subtest 'the guest fetches what its build needs' => sub {
    my ( $status, $err, $got ) = fetch('payload.host.test/data.tar.gz');
    is( $status, 0, 'the payload' ) or diag $err;
    is_deeply( $got, { 'data.tar.gz' => 'the payload of host.test' }, 'arrives whole' );

    ( $status, $err, $got ) = fetch('data.host.test/');
    is( $status,        0,                                 'the data directory' ) or diag $err;
    is( $got->{served}, 'the data of host.test',           'arrives' );
    is( $got->{escape}, "-> $root/data/other.test/secret", 'and a symlink in it comes as a symlink, not as what it points at' );

    ( $status, $err, $got ) = fetch('skel.host.test/');
    is( $status, 0, 'and a directory that a recipe names' ) or diag $err;
    is_deeply( $got, { '.bashrc' => 'the dotfiles of the admin' }, 'arrives as well' );

    ( $status, $err, $got ) = fetch('payload.tenant.test/data.tar.gz');
    is( $status, 0, 'the payload of a tenant comes with the key of its host, whose guest runs the build of the tenant' ) or diag $err;
    is_deeply( $got, { 'data.tar.gz' => 'the payload of tenant.test' }, 'and it is the payload of the tenant' );
};

subtest 'and nothing else of this machine' => sub {
    my ( $status, $err, $got ) = fetch('payload.host.test/');
    is_deeply( $got, { 'data.tar.gz' => 'the payload of host.test' }, 'the directory of the payload gives the payload, and not the key or the secrets beside it' );

    ( $status, $err, $got ) = fetch('payload.host.test/key.rsa');
    isnt( $status, 0, 'the private key of the guest, asked for by name, is refused' );
    is_deeply( $got, {}, 'and does not arrive' );

    ( $status, $err, $got ) = fetch( 'data.host.test/', '--copy-links' );
    isnt( $status, 0, 'a fetch that follows symlinks is refused, because a symlink can point out of the module' );
    unlike( join( q{}, values %$got ), qr/another[ ]domain/, 'so the data of another domain does not arrive' );

    ( $status, $err, $got ) = fetch('data.host.test/../other.test/secret');
    unlike( join( q{}, values %$got ), qr/another[ ]domain/, 'nor through a path that climbs out of the module' );

    ( $status, $err ) = fetch('nosuch.host.test/');
    isnt( $status, 0, 'a module that is not there is refused' );

    my ( $out, $list_err );
    IPC::Run3::run3( [ 'rsync', "--rsh=$rsh", 'transfer@host.test::' ], \undef, \$out, \$list_err );
    unlike( $out // q{}, qr/host[.]test/, 'and the modules are not listed for a guest that asks' );

    IPC::Run3::run3( [ qw{rsync -r}, "--rsh=$rsh", "$root/skel/", 'transfer@host.test::data.host.test/' ], \undef, \$out, \$list_err );
    isnt( $? >> 8, 0, 'a guest cannot write into a module' );
    ok( !-e "$root/data/host.test/.bashrc", 'and nothing it sent arrived' );
};

subtest 'a module that rsyncd.conf cannot say is refused' => sub {
    like( exception { Trog::Provisioner::Config::Generator::write_rsyncd_conf( $host, 'host.test', 'two words' => '/bogus' ) },                  qr/not[ ]a[ ]name/, 'a name with a space' );
    like( exception { Trog::Provisioner::Config::Generator::write_rsyncd_conf( $host, 'host.test', data        => "/bogus\n[all]\npath = /" ) }, qr/line[ ]break/,   'a path with a line break, which would start a module of its own' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
