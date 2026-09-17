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

Ask a question and hand back what was typed.

C<%opts> reach L<IO::Prompter> untouched: C<-echo> to mask what is typed,
C<-in> and C<-out> to ask somewhere other than standard input.

=head3 Why this is not just IO::Prompter::prompt

IO::Prompter reads from C<*ARGV>, so a program that has arguments -- which
F<bin/provision>, F<bin/new_config> and F<bin/destroy> all do, the domain being
one -- sends it off to open a file named after one of them:

    prompt(): Can't open *ARGV: No such file or directory

Flattening C<@ARGV> to a single string leaves nothing there to open, and it
falls back to the terminal or to standard input as intended.  Every caller needs
that, every caller got it wrong at least once, and it was written out three
times before it was written down here.

The flattening is C<local> to this call, so C<@ARGV> is whatever it was again by
the time this returns.

=cut

sub prompt {
    my ( $message, %opts ) = @_;

    local *ARGV = join ' ', @ARGV;
    return IO::Prompter::prompt( $message, %opts );
}

1;
