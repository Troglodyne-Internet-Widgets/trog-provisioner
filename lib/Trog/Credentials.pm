package Trog::Credentials;

#ABSTRACT: Passwords handed to a run that has nobody to ask.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Trog::Utils();

=head1 NAME

Trog::Credentials - passwords handed to a run that has nobody to ask.

=head1 SYNOPSIS

    use Trog::Credentials();

    my $passphrase = Trog::Credentials->get('keepass');
    my $sudo       = Trog::Credentials->get('sudo');

=head1 DESCRIPTION

This tool asks for two passwords that it cannot store.  One is the passphrase
of the secrets database.  The other is the sudo password on the hypervisor, when
the login there does not have passwordless sudo.

A prompt works when a person is at the terminal.  It does not work when
something else drives the run, for example the reprovision button of tCMS, a
cron job or a CI job.  Those have no terminal.  So the run dies several minutes
in, on a prompt that nobody sees.

Instead, the caller can give them on standard input, before anything runs:

    keepass: correct horse battery staple
    sudo: hunter2

Each line is C<name: value>.  Reading stops at a blank line or at the end of
input.  The order does not matter, but the names do.  Nothing else here reads
standard input, so nothing competes for it.

The names must match exactly.  An unknown name is an error, and is not ignored.
A misspelled C<keypass> that silently meant "prompt for it" makes a run that
hangs, and a hang is what this module prevents.

Whitespace around the value stays, because a password can contain some.  A
value can be empty.

=head2 WHY STANDARD INPUT

Standard input is the one channel that is not the process table, the
environment or a file.  Everybody can read an argument while the process lives.
Anything that can read C</proc> as the same user can read the environment, and
every child inherits it.  A file must be created, given its mode and deleted,
with no failure between those steps.  A pipe has none of these problems.  The
writer holds one end, this process holds the other, and it exists only while
the two talk.

=head2 IT HAS TO BE ASKED FOR

Nothing here reads anything until something calls C<load>.
C<bin/provision --credentials> and C<bin/new_config --credentials> do that.

A read that nobody asked for can hang.  Some callers are not a terminal, have
nothing to give, and never close their end, for example a test harness or a
daemon.  A read from such a caller never returns.  That is the same hang that
this module prevents, only earlier in the run.

If a name was not given, the run asks for it.  So you can give the sudo password
in the block and type the passphrase, if a person is present to type it.

=head1 CLASS METHODS

=cut

# The names a caller can give.  See DESCRIPTION for why an unknown name dies.
our %KNOWN = map { $_ => 1 } qw{keepass sudo};

our %CREDENTIAL;

# Where prompt asks when told to use the terminal.  A test points it at a file.
our $TERMINAL = '/dev/tty';

=head2 prompt($message, $name, %opts)

Returns the password.  It asks for the password only if this run does not
already have it.  Every password this tool asks for comes through here,
including the sudo password that L<Trog::Machine> needs.

C<$name> says which password this is, and must be a name in C<%KNOWN>.  With a
name, a run that has no terminal can give the password in advance, and this
returns it with no prompt.  Without a name, it always asks.

It asks on standard input, or at the terminal that is connected to it.  The
option C<terminal> makes it ask at F</dev/tty> instead.  Use that when standard
input is already in use.  For example, C<bin/add_secret --stdin> reads the
secret from standard input, so nothing is left there to answer a prompt.

An empty answer is a valid answer.

Dies if the input ends before an answer, and does not return an empty password.
Dies if C<terminal> is set and it cannot open the terminal.  Dies after it asks
if C<$name> is not a known name.

=cut

sub prompt {
    my ( $class, $message, $name, %opts ) = @_;
    $message //= 'Enter password:';
    my $what = $name // 'a password';

    return $class->get($name) if defined $name && $class->have($name);

    my @at = $opts{terminal} ? ( -in => _terminal( '<', $what ), -out => _terminal( '>>', $what ) ) : ();

    my $answer = Trog::Utils::prompt( $message, -echo => '*', @at );

    # The answer is false only when no line arrived.  An empty line is true.
    die "Nothing was typed for $what: its input ended before an answer.\n" unless $answer;

    my $typed = "$answer";
    $class->remember( $name, $typed ) if defined $name;

    return $typed;
}

# Opens the terminal with $mode, for IO::Prompter to ask at.
sub _terminal {
    my ( $mode, $what ) = @_;
    open( my $fh, $mode, $TERMINAL ) or die "Cannot ask for $what at a terminal: $TERMINAL: $!\n" . "Standard input is already spoken for, so it has to be typed there.\n";
    return $fh;
}

=head2 remember($name, $value)

Keeps a credential that a person typed, so that the rest of the run does not
ask for it again.

A provision reads the store two times.  The first fills in the C<secret:> notes
of a configuration.  The second puts on the guest the files that a recipe reads
but must not generate.  A second prompt is worse than a nuisance, because the
usual caller pipes the answer in, and a pipe answers once.

Returns 1.  Dies if C<$name> is not a known name.

=cut

sub remember {
    my ( $class, $name, $value ) = @_;

    die "Unknown credential '$name'.\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
      unless $KNOWN{$name};

    $CREDENTIAL{$name} = $value;
    return 1;
}

=head2 get($name)

Returns the credential, or undef if it was not given.

=cut

sub get {
    my ( $class, $name ) = @_;
    return $CREDENTIAL{$name};
}

=head2 have($name)

Returns 1 if the credential was given, and 0 if not, without reading it.  In a
boolean test, C<get> is false for an empty value and for a missing one.

=cut

sub have {
    my ( $class, $name ) = @_;
    return exists $CREDENTIAL{$name} ? 1 : 0;
}

=head2 load($fh)

Reads the block.  C<$fh> defaults to standard input.  A test passes its own
handle.

This is what C<--credentials> does.  C<bin/provision --credentials> and
C<bin/new_config --credentials> call it once, before anything that can want a
password.  Nothing else calls it.  See L</IT HAS TO BE ASKED FOR>.

C<prompt> gets one credential when something wants it, and on a pipe that is
the next line that arrives.  C<load> takes several credentials at once, each
with a name, so the order of the requests does not matter.  A run with no
terminal can need the passphrase of the store and a sudo password.  It cannot
know which it needs first.  So pipe a block, not a bare password:

    printf 'keepass: %s\nsudo: %s\n\n' "$STORE_PASS" "$SUDO_PASS" \
        | bin/provision --credentials some.domain

C<prompt> looks first at what this reads, so nothing asks again for a password
given here.

Returns 1.  Dies if a line is not C<name: value>, or if a name is not known.

=cut

sub load {
    my ( $class, $fh ) = @_;
    $fh //= \*STDIN;

    while ( my $line = <$fh> ) {
        chomp $line;
        last unless $line;

        my ( $name, $value ) = $line =~ m/^(\w+):[ ]?(\N*)$/;
        die "Could not read the credentials given on standard input.\n" . "Expected 'name: value', got: $line\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
          unless defined $name;

        die "Unknown credential '$name' given on standard input.\n" . 'Known names: ' . join( ', ', sort keys %KNOWN ) . "\n"
          unless $KNOWN{$name};

        $CREDENTIAL{$name} = $value;
    }

    return 1;
}

=head2 forget()

Drops every credential that C<load> or C<remember> kept.  Only tests need this.

=cut

sub forget {
    %CREDENTIAL = ();
    return 1;
}

=head1 SEE ALSO

L<Trog::Secrets>, which opens the store with the passphrase.

L<Trog::Machine>, which asks for the sudo password.

=cut

1;
