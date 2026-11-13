#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/import_sieve.t - scripts/import_sieve: the sieve script that a store brings
becomes the active script of ManageSieve, and a store that ManageSieve already
keeps stays as it is

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Fcntl            qw{S_IMODE};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;

my $script = "$FindBin::Bin/../scripts/import_sieve";

# The home of an account named someuser, with the files in %files, and links
# from the names in %links to their targets.
sub home_with {
    my (%opts) = @_;
    my $home = tempdir( CLEANUP => 1 );
    foreach my $path ( sort keys %{ $opts{files} // {} } ) {
        if ( $path =~ m{\A(.*)/} && !-d "$home/$1" ) {
            mkdir "$home/$1" or die "mkdir: $!";
        }
        File::Slurper::Temp::write_text( "$home/$path", $opts{files}{$path} );
    }
    foreach my $link ( sort keys %{ $opts{links} // {} } ) {
        symlink( $opts{links}{$link}, "$home/$link" ) or die "symlink: $!";
    }
    return $home;
}

sub import_sieve {
    my ($home) = @_;
    IPC::Run3::run3( [ $script, $home, 'someuser' ], \undef, \my $out, \my $err );
    return ( $? >> 8, $out . $err );
}

my $RULES = qq{require "fileinto";\nif header :contains "subject" "x" { fileinto "x"; }\n};

subtest 'a store from a server with no ManageSieve' => sub {
    my $home = home_with(
        files => { 'someuser.sieve' => $RULES, '.dovecot.svbin' => 'stale' },
        links => { '.dovecot.sieve' => 'someuser.sieve' },
    );
    my ( $status, $said ) = import_sieve($home);
    is( $status, 0, 'it exits 0' ) or diag $said;

    is( File::Slurper::read_text("$home/sieve/someuser.sieve"), $RULES, 'the script is in the storage of ManageSieve' );
    ok( !-e "$home/someuser.sieve", 'and not where it was, so there is one copy to edit' );
    is( readlink("$home/.dovecot.sieve"),     'sieve/someuser.sieve', 'and the active link names it inside the storage, as ManageSieve writes it' );
    is( S_IMODE( ( stat "$home/sieve" )[2] ), oct 2750,               'the storage is 2750, as the rest of the mail store is' );
    ok( !-e "$home/.dovecot.svbin", 'and the binary of the old link is gone' );
    like( $said, qr{someuser[.]sieve}, 'and the log says what moved' );

    ( $status, $said ) = import_sieve($home);
    is( $status,                          0,                      'a second run exits 0' );
    is( readlink("$home/.dovecot.sieve"), 'sieve/someuser.sieve', 'and changes nothing' );
    is( $said,                            q{},                    'and says nothing' );
};

subtest 'a store from a server that ran ManageSieve stays as it is' => sub {
    my $home = home_with(
        files => { 'someuser.sieve' => 'old', 'sieve/chosen.sieve' => $RULES, 'sieve/other.sieve' => $RULES },
        links => { '.dovecot.sieve' => 'sieve/chosen.sieve' },
    );
    my ( $status, $said ) = import_sieve($home);
    is( $status,                                          0,                    'it exits 0' ) or diag $said;
    is( readlink("$home/.dovecot.sieve"),                 'sieve/chosen.sieve', 'the script that the user chose is still the active one' );
    is( File::Slurper::read_text("$home/someuser.sieve"), 'old',                'and the file beside it stays where it was' );
    ok( !-e "$home/sieve/someuser.sieve", 'and does not join the storage' );
};

subtest 'an account with no script of its own' => sub {
    my $home = home_with();
    my ( $status, $said ) = import_sieve($home);
    is( $status, 0, 'it exits 0' ) or diag $said;
    ok( !-e "$home/sieve" && !-l "$home/.dovecot.sieve", 'and makes no storage and no link' );
};

had_no_warnings();
done_testing;
