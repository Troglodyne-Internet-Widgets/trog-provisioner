#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Trog-Utils.t - Trog::Utils: the small things more than one program needs

=cut

use Test::More;
use Test::MockModule qw{strict};
use File::Temp();

use FindBin::libs;

# Loaded so Test::MockModule has a package to attach to: Trog::Utils names it
# only inside the sub under test.
use IO::Prompter();
use Trog::Utils();

subtest 'a prompt is asked with nothing left in @ARGV for it to open' => sub {

    # The whole reason this sub exists: IO::Prompter reads from *ARGV, so a
    # program with arguments dies opening a file named after one.
    my ( @saw_args, @asked );
    my $mock = Test::MockModule->new('IO::Prompter');
    $mock->redefine(
        prompt => sub {
            my ( $message, %opts ) = @_;
            push @saw_args, scalar @ARGV;
            push @asked, { message => $message, opts => \%opts };
            return 'what was typed';
        }
    );
    my $utils = Test::MockModule->new('Trog::Utils');
    $utils->redefine( output_is_redirected => sub { return 0 } );

    local @ARGV = qw{vm.example.test --dryrun};

    is( Trog::Utils::prompt('Which one?'), 'what was typed', 'hands back what was typed' );
    is( $saw_args[0],                      0,                'and IO::Prompter saw no arguments to go opening a file named after' );

    # local, so a program reading @ARGV after asking does not find it emptied.
    is_deeply( \@ARGV, [qw{vm.example.test --dryrun}], 'which are put back when the call returns' );

    is( $asked[0]{message}, 'Which one?', 'the message reaches IO::Prompter' );
    is_deeply( $asked[0]{opts}, {}, 'and nothing is added to it that the caller did not ask for' );

    # What Trog::Credentials needs: a masked answer, asked somewhere other than
    # standard input.
    Trog::Utils::prompt( 'Secret?', -echo => '*', -in => \*STDIN );
    is( $asked[1]{opts}{-echo}, '*', 'options reach IO::Prompter untouched' );
    ok( exists $asked[1]{opts}{-in}, 'including the handle to ask at' );
};

subtest 'a question is asked at the terminal when only the output is redirected' => sub {
    my @asked;
    my $prompter = Test::MockModule->new('IO::Prompter');
    $prompter->redefine(
        prompt => sub {
            my ( $message, %opts ) = @_;
            print { $opts{-out} } "$message\n" if $opts{-out};
            push @asked, \%opts;
            return 'typed';
        }
    );

    my $redirected = 1;
    my $utils      = Test::MockModule->new('Trog::Utils');
    $utils->redefine( output_is_redirected => sub { return $redirected } );

    my $tty = File::Temp->new();
    local $Trog::Utils::TERMINAL = $tty->filename;

    is( Trog::Utils::prompt('Which one?'), 'typed', 'hands back what was typed' );
    my $out = $asked[0]{-out};
    ok( $out,          'the question goes to a handle of its own' ) or return;
    ok( !$out->opened, 'which is closed once the answer is in' );
    open( my $read, '<', $tty->filename ) or die "Cannot read $Trog::Utils::TERMINAL: $!";
    my $shown = do { local $/; <$read> };
    close($read) or die "Cannot close $Trog::Utils::TERMINAL: $!";
    is( $shown, "Which one?\n", 'and the question was written to the terminal' );
    ok( !exists $asked[0]{-in}, 'the answer is still read from standard input' );

    Trog::Utils::prompt( 'Secret?', -out => \*STDERR );
    is( $asked[1]{-out}, \*STDERR, 'a -out that the caller gave is used as given' );

    local $Trog::Utils::TERMINAL = '/bogus/tty';
    Trog::Utils::prompt('Which one?');
    ok( !exists $asked[2]{-out}, 'with no terminal to open, it asks as it would have' );

    $redirected = 0;
    local $Trog::Utils::TERMINAL = $tty->filename;
    Trog::Utils::prompt('Which one?');
    ok( !exists $asked[3]{-out}, 'with the output at a terminal, it is left where it is' );
};

subtest 'output_is_redirected: no person to answer, so no question to show' => sub {
    open( my $null, '<', '/dev/null' ) or die "Cannot open /dev/null: $!";
    local *STDIN = $null;
    ok( !Trog::Utils::output_is_redirected(), 'standard input that is not a terminal is not a person typing' );
    close($null) or die "Cannot close /dev/null: $!";
};

subtest 'interactive: nobody to ask without a terminal at standard input' => sub {
    open( my $null, '<', '/dev/null' ) or die "Cannot open /dev/null: $!";
    local *STDIN = $null;
    is( Trog::Utils::interactive(), 0, 'standard input that is not a terminal is nobody who can answer' );
    close($null) or die "Cannot close /dev/null: $!";
};

subtest 'slots_in: every place in a structure, with its path' => sub {
    my $config = { nginx => { listen => [ { port => 80 }, 443 ] }, bare => undef, empty => {} };
    my @slots  = Trog::Utils::slots_in( \$config );

    is_deeply(
        [ map { $_->[0] } @slots ],
        [ q{}, qw{bare empty nginx nginx.listen nginx.listen[0] nginx.listen[0].port nginx.listen[1]} ],
        'the root first, then each parent before what is under it, keys sorted and lists in order'
    );
    my %at = map { $_->[0] => $_->[1] } @slots;
    is( ${ $at{'nginx.listen[1]'} }, 443, 'a slot refers to the value at its path' );
    ok( exists $at{bare} && !defined ${ $at{bare} }, 'an undef is a place too' );

    ${ $at{'nginx.listen[0].port'} } = 8080;
    is( $config->{nginx}{listen}[0]{port}, 8080, 'and an assignment through a slot changes the structure' );

    is_deeply( [ map { $_->[0] } Trog::Utils::slots_in( \{ a => 1 }, 'top' ) ], [qw{top top.a}], 'a path for the root is the prefix of every path' );
    is_deeply( [ map { $_->[0] } Trog::Utils::slots_in( \'plain' ) ],           [q{}],           'a plain value is one place' );

    # A call for each level would warn Deep recursion at a hundred, which the
    # FATAL warnings of this file make a death.
    my $deep = [];
    my $at   = $deep;
    $at = ( $at->[0] = [] ) for 1 .. 500;
    is( scalar( () = Trog::Utils::slots_in( \$deep ) ), 501, 'five hundred levels deep, without a call for each' );
};

subtest 'slot_steps: a path of slots_in, back into its steps' => sub {
    is_deeply( [ Trog::Utils::slot_steps('nginx.listen[0].port') ], [ 'nginx', 'listen', 0, 'port' ], 'each key, and each index as a number' );
    is_deeply( [ Trog::Utils::slot_steps('hosts[1]') ],             [ 'hosts', 1 ],                   'an index at the end' );
    is_deeply( [ Trog::Utils::slot_steps(q{}) ],                    [],                               'and nothing for the root' );

    my $config = { a => [ { b => 'c' } ] };
    my ($deep) = grep { ref ${ $_->[1] } eq q{} } Trog::Utils::slots_in( \$config );
    is_deeply( [ Trog::Utils::slot_steps( $deep->[0] ) ], [ 'a', 0, 'b' ], 'which is the path that slots_in gave' );
};

done_testing();
