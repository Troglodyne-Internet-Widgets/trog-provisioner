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

    # The whole reason this sub exists.  IO::Prompter reads from *ARGV, so a
    # program with arguments -- every one of these has a domain -- sends it off
    # to open a file named after one and dies before anybody is asked anything.
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

    # local, so the caller's own arguments are still there afterwards -- a
    # program that read @ARGV after asking a question would otherwise find it
    # emptied under it.
    is_deeply( \@ARGV, [qw{vm.example.test --dryrun}], 'which are put back when the call returns' );

    is( $asked[0]{message}, 'Which one?', 'the message reaches IO::Prompter' );
    is_deeply( $asked[0]{opts}, {}, 'and nothing is added to it that the caller did not ask for' );

    # What Trog::Credentials needs of it: a masked answer, and somewhere other
    # than standard input to ask at.
    Trog::Utils::prompt( 'Secret?', -echo => '*', -in => \*STDIN );
    is( $asked[1]{opts}{-echo}, '*', 'options reach IO::Prompter untouched' );
    ok( exists $asked[1]{opts}{-in}, 'including the handle to ask at' );
};

done_testing();
