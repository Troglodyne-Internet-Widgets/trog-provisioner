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
