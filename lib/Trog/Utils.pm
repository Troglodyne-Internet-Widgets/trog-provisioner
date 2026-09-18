package Trog::Utils;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

use IO::Prompter();

=head1 NAME

Trog::Utils - the small things more than one of these programs needs

=head1 SYNOPSIS

    use Trog::Utils();

    my $answer = Trog::Utils::prompt('Destroy it and rebuild, or stop? [destroy/stop]:');
    my $secret = Trog::Utils::prompt( 'Enter password:', -echo => '*' );

=head1 SUBROUTINES

=head2 prompt($message, %opts)

Ask a question and hand back what was typed.  C<%opts> reach L<IO::Prompter>
untouched: C<-echo> to mask what is typed, C<-in> and C<-out> to ask somewhere
other than standard input.

Call this rather than C<IO::Prompter::prompt>, which reads from C<*ARGV> and so
dies with C<Can't open *ARGV> in any program that has arguments -- the domain
being one here.  C<@ARGV> is flattened for the call and C<local> to it, so it is
whatever it was again by the time this returns.

=cut

sub prompt {
    my ( $message, %opts ) = @_;

    local *ARGV = join ' ', @ARGV;
    return IO::Prompter::prompt( $message, %opts );
}

1;
