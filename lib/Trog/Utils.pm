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

Asks a question and returns what the user typed.  C<%opts> go to
L<IO::Prompter> unchanged.  For example, C<-echo> masks what the user types, and
C<-in> and C<-out> ask somewhere other than standard input.

Call this and not C<IO::Prompter::prompt>.  That sub reads from C<*ARGV>, so it
dies with C<Can't open *ARGV> in a program that has arguments, such as a domain.
This sub makes C<*ARGV> C<local> to the call, so C<@ARGV> is the same again when
it returns.

=cut

sub prompt {
    my ( $message, %opts ) = @_;

    local *ARGV = join ' ', @ARGV;
    return IO::Prompter::prompt( $message, %opts );
}

1;
