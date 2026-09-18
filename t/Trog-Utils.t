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

done_testing();
