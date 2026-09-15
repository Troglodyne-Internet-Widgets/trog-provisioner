#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/pod-see-also.t - nothing but paragraphs under a SEE ALSO

=head1 DESCRIPTION

Pod::Weaver::Section::SeeAlso, which F<weaver.ini> uses, dies on anything under
C<=head1 SEE ALSO> that is not an ordinary paragraph.  And Pod::Elemental nests
every C<=head2> under the C<=head1> above it, whatever code lies between -- so a
sub documented anywhere below a SEE ALSO is inside it, and stops C<dzil
listdeps>, which is how a trogrunner guest learns what its checkout needs.

=cut

use Test::More;
use File::Find ();

use FindBin;

my $root = "$FindBin::Bin/..";

my @files;
File::Find::find( sub { push @files, $File::Find::name if !-d && ( /\.pm\z/ || $File::Find::dir =~ m{/bin\z} ) }, "$root/lib", "$root/bin" );
ok( scalar( grep { m{/lib/.+\.pm\z} } @files ), "found the modules under $root/lib to read" ) or BAIL_OUT('there is nothing to check');

foreach my $file ( sort @files ) {
    open( my $fh, '<', $file ) or die "$file: $!";
    my ( $has, @nested ) = see_also($fh);
    close($fh) or die "Could not close $file: $!";
    next unless $has;

    ( my $name = $file ) =~ s{\A\Q$root\E/}{};
    is_deeply( \@nested, [], "$name has only paragraphs under its SEE ALSO, which is all dzil's SeeAlso section will read" )
      or diag( 'Move SEE ALSO below these, or give them a =head1 of their own:', "\n", @nested );
}

done_testing();

# Whether the POD has a SEE ALSO, and every command paragraph nested inside one.
sub see_also {
    my ($fh) = @_;
    my ( $has, $under, @nested );
    while ( my $line = <$fh> ) {
        if ( $line =~ /^=head1\s+(.*)/ ) {
            $under = $1 =~ /^SEE\s+ALSO/;
            $has ||= $under;
            next;
        }
        push @nested, "line $.: $line" if $under && $line =~ /^=(?!cut\b|pod\b)\w/;
    }
    return ( $has, @nested );
}
