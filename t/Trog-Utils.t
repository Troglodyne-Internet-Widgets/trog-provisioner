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
