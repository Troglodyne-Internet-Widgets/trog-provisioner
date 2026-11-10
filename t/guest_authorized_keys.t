#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/guest_authorized_keys.t - scripts/guest_authorized_keys: which keys sshd
lets in for the account that guests fetch as, and what each may run

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();
use FindBin;
use FindBin::libs;

my $script  = "$FindBin::Bin/../scripts/guest_authorized_keys";
my $sandbox = "$FindBin::Bin/../scripts/rsyncd_sandbox";

my $KEY = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ+/x==';

# What the script prints for a directory of keys, by line, and its exit status.
sub lines_for {
    my (%files) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/$_", $files{$_} ) for keys %files;

    my ( $out, $err );
    IPC::Run3::run3( [ $^X, $script, $dir, 'fetcher' ], \undef, \$out, \$err );
    diag $err if $err;
    return ( [ split /\n/, $out ], $? >> 8 );
}

subtest 'each guest key, with no command but the sandbox of its domain directory' => sub {
    my ( $lines, $rc ) = lines_for(
        'a.test.test' => "/bogus/domains/a.test.test\n$KEY a.test.test\n",
        'b.test.test' => "/bogus/domains/b.test.test\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAb\n",
    );
    is( $rc, 0, 'it exits 0' );
    is_deeply(
        $lines,
        [ qq{command="$sandbox /bogus/domains/a.test.test",restrict $KEY}, qq{command="$sandbox /bogus/domains/b.test.test",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAb}, ],
        'one line each, in the order of the names, the sandbox beside the script, and the comment of the key dropped'
    );
};

subtest 'and nothing that a writer of the directory adds gets more' => sub {
    my ( $lines, $rc ) = lines_for(
        'options.test.test' => qq{/bogus/d\nno-pty,command="sh" $KEY\n},
        'quote.test.test'   => qq{/bogus/d",command="sh\n$KEY\n},
        'space.test.test'   => "/bogus/d -x\n$KEY\n",
        'relative.test'     => "bogus/d\n$KEY\n",
        'two.test.test'     => "/bogus/d\n$KEY\n$KEY\n",
        'onlyone.test.test' => "/bogus/d\n",
        'type.test.test'    => "/bogus/d\nssh-dss AAAA\n",
        '.hidden'           => "/bogus/d\n$KEY\n",
        'not_a_name'        => "/bogus/d\n$KEY\n",
    );
    is( $rc, 0, 'it exits 0, because sshd still has the authorized_keys of the account to read' );
    is_deeply( $lines, [], 'and lets none of them in: options, a quote or a space in the path, a relative path, a second key, no key, a type it does not know, or a file that is not named for a domain' );
};

subtest 'a directory that it cannot read' => sub {
    my ( $out, $err );
    IPC::Run3::run3( [ $^X, $script, '/bogus/no/such/dir' ], \undef, \$out, \$err );
    isnt( $? >> 8, 0, 'fails' );
    like( $err, qr/cannot[ ]read/, 'saying why' );
    is( $out, q{}, 'and lets nothing in' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
