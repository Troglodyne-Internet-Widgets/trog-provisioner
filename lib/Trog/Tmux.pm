package Trog::Tmux;

#ABSTRACT: show the state of a long run on the tmux window of its terminal

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

use POSIX();
use IPC::Run3();

=head1 NAME

Trog::Tmux - show the state of a long run on the tmux window of its terminal

=head1 SYNOPSIS

    use Trog::Tmux();

    my $badge = Trog::Tmux->badge('provision');
    $badge->set('building') if $badge;

    # Any prompt of the run, which shows asking until it returns.
    my $answer = Trog::Tmux->asking( sub { <$tty> } );

    $badge->finish($exit_status) if $badge;

=head1 DESCRIPTION

A run that takes many minutes, such as F<bin/provision>, sets the window
options C<@NAME_state> and C<@NAME_since> on the tmux window of its pane.  A
tmux configuration draws them after the name of the window, as
F</etc/tmux.conf.d/provision.conf> of L<Provisioner::Recipe::trogrunner> does.
Then a window that you do not look at says whether its build is still going,
waits for an answer, or ended, and how.

The states are C<building>, C<asking>, C<ok> and C<failed>.  C<asking>,
C<ok> and C<failed> also ring the bell in the terminal, so the window gets the
bell flag of tmux.  When C<ok> or C<failed> comes in the window that an
attached client is looking at, the end is already seen, so the options are
removed and the bell does not ring.  C<@NAME_since> is the time, as C<HH:MM>,
at which the state began.

Only a job in the foreground of its terminal gets a badge.  A job in the
background, or a command that Claude Code runs, which has no terminal, would
replace the state of the job that you watch in the same window.

=head1 METHODS

=head2 $badge = Trog::Tmux->badge($name)

Returns a badge for the window of C<$TMUX_PANE>, or nothing when the process
runs outside tmux or is not in the foreground of its terminal.  C<$name> is the
prefix of the window options, in lower case letters.  The badge is also the
one that C<asking> uses.  Dies on a C<$name> that is not lower case letters.

=cut

# The terminal that the run is in the foreground of.  A test points it elsewhere.
our $TTY = '/dev/tty';

# The badge of this process, which asking() updates.
our $CURRENT;

sub badge {
    my ( $class, $name ) = @_;
    die "The name of a tmux badge is lower case letters, not '" . ( $name // q{} ) . "'\n" unless ( $name // q{} ) =~ m/\A[[:lower:]]+\z/;

    my $pane = $ENV{TMUX_PANE} // q{};
    return if !$ENV{TMUX} || $pane eq q{} || !$class->foreground();

    $CURRENT = bless { name => $name, pane => $pane }, $class;
    return $CURRENT;
}

=head2 $bool = Trog::Tmux->foreground()

True when this process is in the foreground process group of its controlling
terminal.  Standard input does not decide it, because a run can read a password
from a pipe and still be the job that you watch.

=cut

sub foreground {
    open( my $tty, '<', $TTY ) or return 0;
    my $group = POSIX::tcgetpgrp( fileno $tty );
    close($tty) or return 0;
    return ( $group > 0 && $group == getpgrp() ) ? 1 : 0;
}

=head2 $badge->set($state)

Sets the state, as L</DESCRIPTION> says, and returns it.  A failure of tmux is
ignored, because a badge must not stop the run that it shows.

=cut

sub set {
    my ( $self, $state )  = @_;
    my ( $pane, $option ) = ( $self->{pane}, "\@$self->{name}" );
    $self->{state} = $state;

    if ( ( $state eq 'ok' || $state eq 'failed' ) && $self->watched() ) {
        $self->tmux( qw{set -wu -t}, $pane, "${option}_state" );
        $self->tmux( qw{set -wu -t}, $pane, "${option}_since" );
        return $state;
    }

    $self->tmux( qw{set -w -t}, $pane, "${option}_state", $state );
    $self->tmux( qw{set -w -t}, $pane, "${option}_since", POSIX::strftime( '%H:%M', localtime ) );
    $self->bell() unless $state eq 'building';
    return $state;
}

=head2 $badge->finish($status)

Sets C<ok> when C<$status>, an exit status, is 0, and C<failed> otherwise.

=cut

sub finish {
    my ( $self, $status ) = @_;
    return $self->set( $status ? 'failed' : 'ok' );
}

=head2 @result = Trog::Tmux->asking($code)

Runs C<$code>, a prompt, and returns what it returns, in the context of the
call.  While it runs, the badge from C<badge> shows C<asking>, and afterwards
the state that it showed before, also when C<$code> dies.  Without a badge it
only runs C<$code>.

=cut

sub asking {
    my ( $class, $code ) = @_;
    my $self = $CURRENT;
    return $code->() unless $self;

    my $before = $self->{state};
    $self->set('asking');
    my $want   = wantarray;
    my @result = eval { $want ? $code->() : scalar $code->() };
    my $error  = $@;
    $self->set($before) if defined $before;
    die $error          if $error;
    return $want ? @result : $result[0];
}

=head2 $bool = $badge->watched()

True when an attached client is looking at the window of the badge.

=cut

sub watched {
    my ($self) = @_;
    return ( $self->tmux( qw{display -p -t}, $self->{pane}, '#{&&:#{window_active},#{session_attached}}' ) // q{} ) eq '1';
}

=head2 $badge->bell()

Rings the bell in the terminal of the run.

=cut

sub bell {
    open( my $tty, '>>', $TTY ) or return;
    print {$tty} "\a";
    close($tty) or return;
    return 1;
}

=head2 $out = $badge->tmux(@args)

Runs C<tmux> with C<@args>, and returns what it printed, without the last
newline.  Returns nothing when tmux is not there or fails.

=cut

sub tmux {
    my ( $self, @args ) = @_;
    my ( $out,  $err )  = ( q{}, q{} );
    my $ran = eval { IPC::Run3::run3( [ 'tmux', @args ], \undef, \$out, \$err ); 1 };
    return unless $ran && $? == 0;
    chomp $out;
    return $out;
}

1;
