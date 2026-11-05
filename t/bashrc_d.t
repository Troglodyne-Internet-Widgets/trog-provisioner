#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/bashrc_d.t - scripts/bashrc_d: what a shell of the user gets, and what the .bashrc keeps

=cut

use Test::More;
use Test::NoWarnings qw{had_no_warnings};
use Test::Fatal      qw{exception};
use Test::MockModule;
use Fcntl      qw{S_IMODE};
use File::Temp qw{tempdir};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/bashrc_d";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# passwd names a real home, so every user here lives in a temporary one.
my $home;
my $passwd = Test::MockModule->new( 'Trog::BashrcD', no_auto => 1 );
$passwd->redefine( account => sub { return ( $<, ( split m/[ ]/, $( )[0], $home ) } );

my $files = tempdir( CLEANUP => 1 );

sub snippet {
    my ( $name, $text ) = @_;
    File::Slurper::Temp::write_text( "$files/$name", $text );
    return "$files/$name";
}

sub bashrc {
    return do { local ( @ARGV, $/ ) = "$home/.bashrc"; <> }
      // q{};
}

# What an interactive bash of the user prints, as a terminal would start it.
sub shell_says {
    my ($command) = @_;
    local $ENV{HOME} = $home;
    IPC::Run3::run3( [ 'bash', '-ic', $command ], \undef, \my $out, \my $err );
    return $out;
}

subtest 'a home with no .bashrc gets one that sources the directory' => sub {
    $home = tempdir( CLEANUP => 1 );
    is( Trog::BashrcD::main( 'someone', '10-first', snippet( one => "export SEEN=one\n" ) ), 0,                        'it exits 0' );
    is( shell_says('echo $SEEN'),                                                            "one\n",                  'and an interactive shell of the user runs the file' );
    is( bashrc(),                                                                            "$Trog::BashrcD::LOOP\n", 'from a .bashrc that holds the loop alone' );
    is( S_IMODE( ( stat "$home/.bashrc.d/10-first" )[2] ),                                   oct 644,                  'and the file is 0644' );
};

subtest 'a .bashrc of the user keeps what it has, and gets the loop once' => sub {
    $home = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$home/.bashrc", "export MINE=kept" );
    Trog::BashrcD::main( 'someone', '20-second', snippet( two => "export SEEN=\"\$SEEN,two\"\n" ) );
    Trog::BashrcD::main( 'someone', '10-first',  snippet( one => "export SEEN=one\n" ) );
    is( bashrc(),                       "export MINE=kept\n$Trog::BashrcD::LOOP\n", 'the loop goes on a line of its own after the last line, and a second run adds no second loop' );
    is( shell_says('echo $MINE $SEEN'), "kept one,two\n",                           'and the shell runs the .bashrc, then each file in the order of its name' );

    Trog::BashrcD::main( 'someone', '10-first', snippet( one => "export SEEN=again\n" ) );
    is( shell_says('echo $SEEN'), "again,two\n", 'a file of the same name is replaced' );
};

subtest 'it refuses what it cannot install' => sub {
    $home = tempdir( CLEANUP => 1 );
    my $file = snippet( ok => "true\n" );
    foreach my $name ( qw{.hidden ../escape a/b}, join( q{ }, qw{sp ace} ), q{} ) {
        like( exception { Trog::BashrcD::main( 'someone', $name, $file ) }, qr/NAME|usage/, "it refuses the name '$name'" );
    }
    like( exception { Trog::BashrcD::main(qw{someone x /bogus}) }, qr/not[ ]a[ ]file[ ]that[ ]can[ ]be[ ]read/, 'and a file that is not there' );
    ok( !-e "$home/.bashrc", 'and changes no .bashrc when it refuses' );

    $passwd->unmock('account');
    like( exception { Trog::BashrcD::main( 'bogus-no-such-user', 'x', $file ) }, qr/No[ ]user/, 'and a user that passwd does not know' );
};

had_no_warnings();

done_testing();
