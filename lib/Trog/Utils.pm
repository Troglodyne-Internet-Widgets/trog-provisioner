package Trog::Utils;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

use IO::Prompter();
use IO::Interactive::Tiny();
use File::Slurper::Temp();

=head1 NAME

Trog::Utils - the small things more than one of these programs needs

=head1 SYNOPSIS

    use Trog::Utils();

    my $answer = Trog::Utils::prompt('Destroy it and rebuild, or stop? [destroy/stop]:');
    my $secret = Trog::Utils::prompt( 'Enter password:', -echo => '*' );

=head1 VARIABLES

=head2 $LIBEXEC

Where a machine that guests fetch from keeps the programs that sshd runs for
their keys, owned by root: F</usr/local/libexec/trog-provisioner>.
F<scripts/setup_transfer_user> installs them there.

=cut

our $LIBEXEC = '/usr/local/libexec/trog-provisioner';

=head2 $GUEST_KEYS

The directory of the guest keys that sshd lets in on such a machine:
F</var/lib/trog-provisioner/guest-keys>.  F<scripts/guest_authorized_keys>
reads it for sshd, and C<authorize_guest_key> in L<Trog::Local> writes it.

=cut

our $GUEST_KEYS = '/var/lib/trog-provisioner/guest-keys';

=head2 $LINK_NAME

A regular expression that matches a name that the kernel takes for a link,
such as a bridge: from 1 to 15 bytes, of ASCII letters, digits, C<_>, C<.> and
C<->, the first a letter or a digit.  So no name that it matches holds a
character that a path or the address of an alias would read.  A schema takes
it as C<"$LINK_NAME">, because a compiled regular expression keeps its flags
when it becomes a string, and the C</aa> among them keeps a letter that is not
ASCII out.

=cut

our $LINK_NAME = qr/\A [[:alnum:]] [[:alnum:]_.-]{0,14} \z/;

=head1 SUBROUTINES

=head2 write_binary_mode($path, $bytes, $mode)

Writes C<$bytes> to C<$path> whole, through L<File::Slurper::Temp>, as they
are, with the mode C<$mode>, whatever the umask of the process is and whatever mode a file
already at C<$path> has.  The temporary file has C<$mode> from the start, and
the rename that puts it in place is atomic, so no reader ever sees C<$path>
partly written or with another mode.  A private key must never be readable by
more than its owner, and a file that another account reads, such as sshd as
C<nobody>, must not lose a bit of its mode to the umask of whoever wrote it.
Returns 1, and dies if it cannot write.

=cut

sub write_binary_mode {
    my ( $path, $bytes, $mode ) = @_;

    # File::Temp hands the mode to sysopen, which takes the umask off it.
    local $File::Slurper::Temp::FILE_TEMP_PERMS = $mode;
    my $umask = umask 0;
    my $ok    = eval { File::Slurper::Temp::write_binary( $path, $bytes ); 1 };
    umask $umask;
    die $@ unless $ok;
    return 1;
}

=head2 prompt($message, %opts)

Asks a question and returns what the user typed.  C<%opts> go to
L<IO::Prompter> unchanged.  For example, C<-echo> masks what the user types, and
C<-in> and C<-out> ask somewhere other than standard input.

Call this and not C<IO::Prompter::prompt>.  That sub reads from C<*ARGV>, so it
dies with C<Can't open *ARGV> in a program that has arguments, such as a domain.
This sub makes C<*ARGV> C<local> to the call, so C<@ARGV> is the same again when
it returns.

If standard input is a terminal and the output is not, for example under
C<&E<gt> file>, the question is asked at F</dev/tty>.  The answer is still read
from standard input.  Without that, L<IO::Prompter> shows neither the question
nor the masked echo, and the program waits with nothing on the screen.  A
C<-out> from the caller is used as given.

=cut

# Where a question goes when the output is redirected.  A test points it at a file.
our $TERMINAL = '/dev/tty';

sub prompt {
    my ( $message, %opts ) = @_;

    # Closed below, after the answer, as $tty: the policy follows only $fh.
    my $tty;
    if ( !exists $opts{-out} && output_is_redirected() && open( my $fh, '>>', $TERMINAL ) ) {    ## no critic (InputOutput::RequireBriefOpen)
        $tty = $opts{-out} = $fh;
    }

    local *ARGV = join ' ', @ARGV;
    my $answer = IO::Prompter::prompt( $message, %opts );
    close($tty) or die "Cannot close $TERMINAL: $!\n" if $tty;
    return $answer;
}

=head2 interactive()

Returns 1 if a person can answer a prompt, and 0 if not: standard input and the
selected output handle are both terminals.  A prompt that nobody answers does
not fail.  It stops the run until something else kills it.  So a caller asks
this before it prompts.

=cut

sub interactive {
    return IO::Interactive::Tiny::is_interactive() ? 1 : 0;
}

=head2 output_is_redirected()

Returns true if standard input is a terminal and the selected output handle is
not.  Then a person can type an answer but cannot see the question.

=cut

sub output_is_redirected {
    return IO::Interactive::Tiny::is_interactive(*STDIN) && !IO::Interactive::Tiny::is_interactive();
}

=head2 @slots = slots_in(\$root, $path)

Returns every place in the structure that C<$root> refers to, the root too,
each as an array reference of its path and a reference to the place.  Read
the value as C<${ $slot->[1] }>, and assign through it to change the
structure.

A path is dotted, with a list item as C<[n]>: C<nginx.listen[0].port>.
C<$path> is the path of the root, and is empty by default.  The places come
parent first, the keys of a hash in sorted order and a list in its own
order, so the answer is the same on every run.

It walks with a list and not with a call for each level.  A call for each level
warns C<Deep recursion> at a hundred levels, and a warning is fatal here.

=cut

sub slots_in {
    my ( $root, $path ) = @_;

    my @stack = ( [ $path // q{}, $root ] );
    my @found;
    while ( my $at = pop @stack ) {
        push( @found, $at );
        my ( $here, $slot ) = @$at;
        my $node = $$slot;

        # Pushed in reverse, so the first child is the next one popped.
        push( @stack, reverse map { [ $here eq q{} ? $_ : "$here.$_", \$node->{$_} ] } sort keys %$node ) if ref $node eq 'HASH';
        push( @stack, reverse map { [ "$here\[$_]", \$node->[$_] ] } 0 .. $#$node ) if ref $node eq 'ARRAY';
    }
    return @found;
}

=head2 @steps = slot_steps($path)

Returns the steps of a path as C<slots_in> spells it: each key, and each list
index as a number.  C<nginx.listen[0].port> is C<nginx>, C<listen>, C<0> and
C<port>.

A path does not quote its keys, so a key that holds a dot or a bracket, such as
a domain name, comes back as more than one step.

=cut

sub slot_steps {
    my ($path) = @_;

    my @steps;
    while ( $path =~ m/([^.\[\]]+)|\[(\d+)\]/g ) {
        push( @steps, $1 // $2 );
    }
    return @steps;
}

1;
