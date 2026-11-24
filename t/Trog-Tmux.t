#!/usr/bin/env perl

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Trog-Tmux.t - Trog::Tmux: the state of a long run on its tmux window

=cut

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use File::Temp();
use File::Slurper();
use File::Slurper::Temp();

use FindBin::libs;

use Trog::Tmux();

# What $? holds for a run that exited 255.
my $FAILED = 65_280;

# A badge whose tmux calls and bells are recorded, and whose window is watched
# or not.  The mock lives as long as the hash.
sub recorded {
    my (%opts) = @_;
    my ( @calls, $bells );
    my $mock = Test::MockModule->new('Trog::Tmux');
    $mock->redefine( tmux    => sub { my ( $self, @args ) = @_; push @calls, \@args; return $opts{said} } );
    $mock->redefine( watched => sub { return $opts{watched} // 0 } );
    $mock->redefine( bell    => sub { $bells++; return 1 } );
    my $badge = bless { name => 'provision', pane => '%7' }, 'Trog::Tmux';
    return { badge => $badge, calls => \@calls, bells => \$bells, mock => $mock };
}

subtest 'only a foreground job in tmux gets a badge' => sub {
    local $Trog::Tmux::CURRENT;
    my $mock = Test::MockModule->new('Trog::Tmux');
    my $fore = 1;
    $mock->redefine( foreground => sub { return $fore } );

    local $ENV{TMUX}      = '/tmp/tmux-1000/default,1,0';
    local $ENV{TMUX_PANE} = '%7';
    my $badge = Trog::Tmux->badge('provision');
    isa_ok( $badge, 'Trog::Tmux', 'a badge in the foreground of a pane' );
    is( $Trog::Tmux::CURRENT, $badge, 'and it is the one that asking uses' );

    $fore = 0;
    local $Trog::Tmux::CURRENT;
    is( Trog::Tmux->badge('provision'), undef, 'none for a job in the background' );
    is( $Trog::Tmux::CURRENT,           undef, 'and asking has none either' );

    $fore = 1;
    {
        local $ENV{TMUX};
        is( Trog::Tmux->badge('provision'), undef, 'none outside tmux' );
    }
    {
        local $ENV{TMUX_PANE} = q{};
        is( Trog::Tmux->badge('provision'), undef, 'none without a pane' );
    }

    like( exception { Trog::Tmux->badge('Provision') },   qr/lower[ ]case[ ]letters,[ ]not[ ]'Provision'/, 'a name with capitals is refused' );
    like( exception { Trog::Tmux->badge('pro vision') },  qr/lower[ ]case[ ]letters/,                      'and one with a space' );
    like( exception { Trog::Tmux->badge("provision\n") }, qr/lower[ ]case[ ]letters/,                      'and one with a newline' );
    like( exception { Trog::Tmux->badge() },              qr/lower[ ]case[ ]letters,[ ]not[ ]''/,          'and no name' );
};

subtest 'a file that is not a terminal is not a foreground' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$dir/plain", q{} );

    local $Trog::Tmux::TTY = "$dir/plain";
    is( Trog::Tmux->foreground(), 0, 'a plain file has no process group' );

    local $Trog::Tmux::TTY = "$dir/bogus";
    is( Trog::Tmux->foreground(), 0, 'and no terminal at all is no foreground' );
};

subtest 'the state of the run goes into two options of its window' => sub {
    my $t = recorded();
    my ( $badge, $calls, $bells ) = @{$t}{qw{badge calls bells}};

    is( $badge->set('building'), 'building', 'set returns the state' );
    is_deeply( $calls->[0], [qw{set -w -t %7 @provision_state building}], 'the state is an option of the window of the pane' );
    is( scalar @{ $calls->[1] }, 6,                  'and so is the time at which it began' );
    is( $calls->[1][4],          '@provision_since', 'in @provision_since' );
    like( $calls->[1][5], qr/\A\d\d:\d\d\z/, 'as HH:MM' );
    is( $$bells, undef, 'a build that is going rings no bell' );

    @$calls = ();
    $badge->set('asking');
    is( $calls->[0][5], 'asking', 'a run that asks says so' );
    is( $$bells,        1,        'and rings the bell, because it waits for you' );
};

subtest 'an end in a window that nobody watches stays until it is seen' => sub {
    my $t = recorded( watched => 0 );
    my ( $badge, $calls, $bells ) = @{$t}{qw{badge calls bells}};

    $badge->finish(0);
    is( $calls->[0][5], 'ok', 'exit status 0 is ok' );
    is( $$bells,        1,    'and rings the bell' );

    @$calls = ();
    $badge->finish($FAILED);
    is( $calls->[0][5], 'failed', 'any other exit status is failed' );
    is( $$bells,        2,        'and rings it too' );
};

subtest 'an end in the window that you watch is already seen' => sub {
    my $t = recorded( watched => 1 );
    my ( $badge, $calls, $bells ) = @{$t}{qw{badge calls bells}};

    is( $badge->finish(0), 'ok', 'the state is still returned' );
    is_deeply( $calls, [ [qw{set -wu -t %7 @provision_state}], [qw{set -wu -t %7 @provision_since}] ], 'but both options are removed' );
    is( $$bells, undef, 'and no bell rings' );

    @$calls = ();
    $badge->set('building');
    is( $calls->[0][5], 'building', 'a build that starts in the watched window still says so' );
};

subtest 'a prompt shows asking while it waits, and the state before afterwards' => sub {
    my $t = recorded();
    my ( $badge, $calls ) = @{$t}{qw{badge calls}};
    local $Trog::Tmux::CURRENT = $badge;
    $badge->set('building');
    @$calls = ();

    my @during;
    my $answer = Trog::Tmux->asking( sub { push @during, $badge->{state}; return 'y' } );
    is( $answer, 'y', 'the answer of the prompt comes back' );
    is_deeply( \@during, ['asking'], 'the badge said asking while it waited' );
    is( $badge->{state}, 'building', 'and building again after the answer' );
    is_deeply( [ map { $_->[5] } grep { $_->[4] eq '@provision_state' } @$calls ], [qw{asking building}], 'tmux was told both' );

    my @list = Trog::Tmux->asking( sub { return ( 1, 2, 3 ) } );
    is_deeply( \@list, [ 1, 2, 3 ], 'a prompt called in list context returns its list' );
    my $last = Trog::Tmux->asking( sub { return ( 1, 2, 3 ) } );
    is( $last, 3, 'and in scalar context, what it returns there' );

    like(
        exception {
            Trog::Tmux->asking( sub { die "input ended\n" } )
        },
        qr/\Ainput[ ]ended$/,
        'a prompt that dies dies again'
    );
    is( $badge->{state}, 'building', 'after the state before it is put back' );
};

subtest 'without a badge, a prompt only runs' => sub {
    local $Trog::Tmux::CURRENT;
    my $mock = Test::MockModule->new('Trog::Tmux');
    $mock->redefine( tmux => sub { fail('no badge, so no tmux') } );
    is( Trog::Tmux->asking( sub { return 'typed' } ), 'typed', 'it returns what the prompt returns' );
    is_deeply( [ Trog::Tmux->asking( sub { return ( 'a', 'b' ) } ) ], [qw{a b}], 'in list context too' );
};

subtest 'a window is watched when an attached client looks at it' => sub {
    my $mock = Test::MockModule->new('Trog::Tmux');
    my ( $said, @asked );
    $mock->redefine( tmux => sub { my ( $self, @args ) = @_; push @asked, \@args; return $said } );
    my $badge = bless { name => 'provision', pane => '%7' }, 'Trog::Tmux';

    $said = '1';
    ok( $badge->watched(), 'tmux says 1' );
    is_deeply( $asked[0], [ qw{display -p -t %7}, '#{&&:#{window_active},#{session_attached}}' ], 'when asked about the window of the pane' );
    $said = '0';
    ok( !$badge->watched(), 'not when it says 0' );
    $said = undef;
    ok( !$badge->watched(), 'and not when tmux does not answer' );
};

subtest 'tmux is asked without a shell, and its failure is no failure of the run' => sub {
    my $badge = bless { name => 'provision', pane => '%7' }, 'Trog::Tmux';
    my $mock  = Test::MockModule->new('IPC::Run3');
    my ( @argv, $exit, $print, $die );
    $mock->redefine(
        run3 => sub {
            my ( $cmd, $in, $out, $err ) = @_;
            die $die if $die;
            @argv = @$cmd;
            $$out = $print;
            $?    = $exit;    ## no critic (Variables::RequireLocalizedPunctuationVars) -- run3 sets it
            return 1;
        }
    );

    ( $exit, $print ) = ( 0, "1\n" );
    is( $badge->tmux(qw{display -p x}), '1', 'it returns what tmux printed, without the newline' );
    is_deeply( \@argv, [qw{tmux display -p x}], 'as one argument each' );

    ( $exit, $print ) = ( 256, "no server running\n" );
    is( $badge->tmux(qw{set -w x y}), undef, 'nothing when tmux fails' );

    $die = "tmux: not found\n";
    is( $badge->tmux(qw{set -w x y}), undef, 'and nothing when there is no tmux' );
};

subtest 'the bell rings in the terminal of the run' => sub {
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    local $Trog::Tmux::TTY = "$dir/tty";
    File::Slurper::Temp::write_text( $Trog::Tmux::TTY, q{} );

    is( Trog::Tmux->bell(),                           1,    'it rings' );
    is( File::Slurper::read_binary($Trog::Tmux::TTY), "\a", 'with one BEL' );

    local $Trog::Tmux::TTY = "$dir/bogus/tty";
    is( Trog::Tmux->bell(), undef, 'and does nothing without a terminal' );
};

done_testing();
