package Trog::Credentials;

#ABSTRACT: Passwords handed to a run that has nobody to ask.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use IO::Prompter();

=head1 NAME

Trog::Credentials - passwords handed to a run that has nobody to ask.

=head1 SYNOPSIS

    use Trog::Credentials();

    my $passphrase = Trog::Credentials->get('keepass');
    my $sudo       = Trog::Credentials->get('sudo');

=head1 DESCRIPTION

This tool asks for two passwords it cannot store: the passphrase to the secrets
database, and the sudo password on the hypervisor when the login there has not
been given passwordless sudo.  Asking works when a person is sitting in front of
it.  It does not work at all when something else is driving -- tCMS's reprovision
button, a cron, a CI job -- because those have no terminal to ask at, and the
run dies several minutes in on a prompt nobody will ever see.

So they can be given up front instead, on standard input, before anything runs:

    keepass: correct horse battery staple
    sudo: hunter2

One C<name: value> per line, read until a blank line or end of input.  Order does
not matter, names do; nothing else here reads standard input, so nothing is
competing for it.

The names are matched exactly, and an unknown one is an error rather than
something to ignore -- a misspelled C<keypass> that quietly meant "prompt for it"
is a run that hangs, which is the thing this exists to prevent.

Whitespace around the value is kept, since a password may legitimately have some,
and a value may be empty.

=head2 WHY STANDARD INPUT

It is the one channel that is neither the process table, the environment, nor a
file.  An argument is world readable for as long as the process lives, the
environment is readable by anything that can read C</proc> as the same user and
is inherited by every child, and a file has to be created, chmodded and deleted
without anything going wrong in between.  A pipe is none of that: the writer
holds one end, this process holds the other, and it exists for as long as the two
are talking.

=head2 IT HAS TO BE ASKED FOR

Nothing here reads anything until something calls C<load>, which is what
C<bin/provision --credentials> and C<bin/new_config --credentials> do.

That is deliberate, and it was not the first design.  Reading standard input
whenever it did not look like a terminal seemed obvious and is a trap: a caller
that is not a terminal, did not intend to hand anything over, and never closes
its end -- a test harness, anything run from a daemon -- blocks here forever on a
read that will never return.  Which is the same hang, moved earlier, and the
whole point of this module is not hanging.  So it is asked for or it does not
happen.

A name that was not given falls back to asking, so handing in the sudo password
and typing the passphrase is a thing you can do -- provided somebody is there to
type it.

=head1 CLASS METHODS

=cut

# Names a caller may ask for.  An allowlist rather than free text: a typo in the
# block should say so at the top of the run, not silently become a prompt in the
# middle of one.
our %KNOWN = map { $_ => 1 } qw{keepass sudo};

our %CREDENTIAL;

=head2 prompt($message, $name)

The password, asked for if this run has not already been given it.

Here rather than in L<Trog::Secrets>, which is where it used to live: what this
does is get a credential, which is what this module is for.  L<Trog::Machine>
wants the same thing when sudo on the far side turns out to need a password,
and one way of asking is better than two.

C<$name> says which password this is, and is what makes it answerable without
asking -- a run driven by something with no terminal hands its passwords in up
front, and this returns one of those rather than prompting.  Leave the name out
and it always asks, which is what you want for something there is no name for.

=cut

sub prompt {
    my ( $class, $message, $name ) = @_;
    $message //= 'Enter password:';

    return $class->get($name) if defined $name && $class->have($name);

    # IO::Prompter reads from *ARGV, so a program that has arguments -- which
    # bin/new_config and bin/provision both do, the domain being one -- sends it
    # off to open a file named after one of them:
    #
    #     prompt(): Can't open *ARGV: No such file or directory
    #
    # Flattening @ARGV to a single string leaves nothing there to open, and it
    # falls back to the terminal or to standard input as intended.
    local *ARGV = join ' ', @ARGV;    ## no critic (CompileTime)
    my $answer = IO::Prompter::prompt( $message, -echo => '*' );

    $class->remember( $name, "$answer" ) if defined $name;

    return $answer;
}

=head2 remember($name, $value)

Keep something that was typed rather than handed in, so that the next thing in
the same run wanting it does not ask again.

A provision resolves the store twice -- once to fill in the C<secret:> notes in
a configuration, once to put the files a recipe reads but must not generate on
the guest -- and asking twice is worse than a nuisance: the usual caller pipes
the answer in, and a pipe answers once.

=cut

sub remember {
    my ( $class, $name, $value ) = @_;

    die "Unknown credential '$name'.\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
      unless $KNOWN{$name};

    $CREDENTIAL{$name} = $value;
    return 1;
}

=head2 get($name)

The credential, or undef if it was not given.

=cut

sub get {
    my ( $class, $name ) = @_;
    return $CREDENTIAL{$name};
}

=head2 have($name)

Whether it was given, without reading it.  C<get> on an empty value and C<get> on
a missing one both look the same otherwise.

=cut

sub have {
    my ( $class, $name ) = @_;
    return exists $CREDENTIAL{$name} ? 1 : 0;
}

=head2 load($fh)

Read the block.  C<$fh> defaults to standard input; pass one in tests.

B<This is what C<--credentials> is.>  C<bin/provision --credentials> and
C<bin/new_config --credentials> call it once, before anything that could want a
password, and nothing else does -- see IT HAS TO BE ASKED FOR.

It is not a slower C<prompt>.  C<prompt> gets one credential at the moment
something wants it, and on a pipe that means whichever line arrives next.  This
takes several at once, each named, so the order they are asked for in does not
matter -- which is the whole point for a run with no terminal that needs both
the store passphrase and a sudo password and cannot know which will be wanted
first.  That is what makes it worth piping a block rather than a bare password:

    printf 'keepass: %s\nsudo: %s\n\n' "$STORE_PASS" "$SUDO_PASS" \
        | bin/provision --credentials some.domain

Everything it reads goes where C<prompt> looks first, so a password given here
is one nothing asks about again.

=cut

sub load {
    my ( $class, $fh ) = @_;
    $fh //= \*STDIN;

    while ( my $line = <$fh> ) {
        chomp $line;
        last unless length $line;

        my ( $name, $value ) = $line =~ m/^(\w+):[ ]?(.*)$/;
        die "Could not read the credentials given on standard input.\n" . "Expected 'name: value', got: $line\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
          unless defined $name;

        die "Unknown credential '$name' given on standard input.\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
          unless $KNOWN{$name};

        $CREDENTIAL{$name} = $value;
    }

    return 1;
}

=head2 forget()

Drop everything read.  Only tests should need this.

=cut

sub forget {
    %CREDENTIAL = ();
    return 1;
}

=head1 SEE ALSO

L<Trog::Secrets>, which asks for the passphrase.

L<Trog::Machine>, which asks for the sudo password.

=cut

1;
