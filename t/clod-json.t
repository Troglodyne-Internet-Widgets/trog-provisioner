#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/clod-json.t - each program that clod.json declares is one that a run of the bot can run

=head1 DESCRIPTION

F<clod.json> tells the bot, App-Clod, which files of this repository its runs
may run.  The bot reads it from the default branch, and gives no rule for an
entry that names no executable file there, and only notes it in its job.  So a
file that moves would quietly take its rule with it.  This asks the same
questions of the checkout, so that the move fails here first.
L<App::Clod::Tasks/declared_rules> is where the bot says what it accepts.

=cut

use Test::More;
use Cpanel::JSON::XS();
use FindBin;

my $root = "$FindBin::Bin/..";

open( my $fh, '<', "$root/clod.json" ) or die "Cannot read clod.json: $!";
my $declared = Cpanel::JSON::XS::decode_json( do { local $/; <$fh> } );
close($fh) or die "Cannot close clod.json: $!";

is( ref $declared->{run}, 'ARRAY', 'clod.json has a list of the paths that a run may run' );

my $name = qr{ (?! \.\.? (?! [^/] ) ) [\w.+] [\w.+-]* };
foreach my $path ( @{ $declared->{run} // [] } ) {
    subtest $path => sub {
        like( $path, qr{\A $name (?: / $name )* (?: / \* )? \z}, 'is a plain path inside the repository, with * only as a final /*' );
        my $dir   = $path =~ s{/\*\z}{/}r;
        my @files = $dir eq $path ? ("$root/$path") : grep { !-d } glob("$root/$dir*");
        foreach my $file (@files) {
            my $shown = $file =~ s{\A\Q$root\E/}{}r;
            if ( -l $file ) {
                like( readlink($file), qr{\A [\w.+-]+ \z}, "$shown links to another file in its directory" );
            }
            else {
                ok( ( ( stat $file )[2] // 0 ) & oct('0111'), "$shown is an executable file" );
            }
        }
        ok( scalar @files, 'and names at least one' );
    };
}

done_testing();
