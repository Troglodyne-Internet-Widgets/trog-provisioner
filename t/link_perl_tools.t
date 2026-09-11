#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/link_perl_tools.t - scripts/link_perl_tools: which tools of the built perl an
account ends up with, and which it does not

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper::Temp();
use IPC::Run3();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/link_perl_tools";

## no critic (ValuesAndExpressions::ProhibitFiletest_rwxRWX)
ok( -x $script, 'link_perl_tools is there and executable' );

## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
my $MODE = 0755;
## use critic

# A guest: perls under one directory, a home the account has, and a getent that
# answers for that account and no other.
sub guest {
    my (%opts) = @_;

    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/home/scratch") unless $opts{no_home};

    foreach my $perl ( @{ $opts{perls} // ['perl5.44.0'] } ) {
        make_path("$dir/perls/$perl/bin");
        foreach my $tool ( @{ $opts{tools} // [qw{perl cpanm prove starman}] } ) {
            File::Slurper::Temp::write_text( "$dir/perls/$perl/bin/$tool", "#!/bin/bash\necho $tool\n" );
            chmod( $MODE, "$dir/perls/$perl/bin/$tool" );
        }
    }

    make_path("$dir/bin");
    File::Slurper::Temp::write_text( "$dir/bin/getent", <<"GETENT" );
#!/bin/bash
[ "\$2" = scratch ] || exit 2
echo "scratch:x:1001:1001::$dir/home/scratch:/usr/sbin/nologin"
GETENT
    chmod( $MODE, "$dir/bin/getent" );

    return $dir;
}

sub link_tools {
    my ( $dir, @args ) = @_;

    local $ENV{PATH}                     = "$dir/bin:$ENV{PATH}";
    local $ENV{LINK_PERL_TOOLS_PERLS}    = "$dir/perls";
    local $ENV{LINK_PERL_TOOLS_ROOT_BIN} = "$dir/root-bin";

    IPC::Run3::run3( [ $script, @args ], \undef, \my $out, \my $err );
    return { status => $? >> 8, out => $out // q{}, err => $err // q{} };
}

sub links {
    my ($bin) = @_;
    return { map { ( s{\A.*/}{}r => readlink $_ ) } grep { -l } glob("$bin/*") };
}

subtest 'the tools that are there, into the account and into root bin' => sub {
    my $dir = guest();
    my $run = link_tools( $dir, 'scratch' );
    is( $run->{status}, 0, 'it exits zero' ) or diag $run->{err};

    my $theirs = links("$dir/home/scratch/bin");
    is_deeply( [ sort keys %$theirs ], [qw{cpanm perl prove starman}], 'every tool the perl has, and nothing it has not' );
    is( $theirs->{starman}, "$dir/perls/perl5.44.0/bin/starman", 'pointing into the perl that was built' );

    # A link to nothing satisfies -e, so anything looking for the tool finds it
    # and then fails at the point of use: dzil and yath were exactly that.
    ok( !-e "$dir/home/scratch/bin/dzil", 'and no link to a tool that was never installed' );

    is_deeply( [ sort keys %{ links("$dir/root-bin") } ], [qw{cpanm perl}], 'root bin gets the two cpan_install finds the perl by' );
};

subtest 'a tool installed later is linked on the run that finds it' => sub {
    my $dir = guest();
    link_tools( $dir, 'scratch' );
    ok( !-e "$dir/home/scratch/bin/dzil", 'not there to begin with' );

    # What a cpan_deps step installs, which is why this runs after them.
    File::Slurper::Temp::write_text( "$dir/perls/perl5.44.0/bin/dzil", "#!/bin/bash\necho dzil\n" );
    chmod( $MODE, "$dir/perls/perl5.44.0/bin/dzil" );

    my $run = link_tools( $dir, 'scratch' );
    is( $run->{status},                         0,                                'run again, it exits zero' );
    is( readlink("$dir/home/scratch/bin/dzil"), "$dir/perls/perl5.44.0/bin/dzil", 'and dzil is linked, rather than waiting for the next provision' );
};

subtest 'the newest perl is the one linked, and a link already there is left alone' => sub {
    my $dir = guest( perls => [qw{perl5.40.0 perl5.44.0}] );
    link_tools( $dir, 'scratch' );
    is( readlink("$dir/home/scratch/bin/perl"), "$dir/perls/perl5.44.0/bin/perl", 'the newest of them' );

    unlink "$dir/home/scratch/bin/perl";
    symlink( "$dir/perls/perl5.40.0/bin/perl", "$dir/home/scratch/bin/perl" );
    link_tools( $dir, 'scratch' );
    is( readlink("$dir/home/scratch/bin/perl"), "$dir/perls/perl5.40.0/bin/perl", 'and one somebody pointed elsewhere is left where it points' );
};

subtest 'what it will not do' => sub {
    my $dir  = guest();
    my $none = link_tools($dir);
    is( $none->{status}, 2, 'no account named is a usage error' );
    like( $none->{err}, qr/usage: link_perl_tools USER/, 'saying what it takes' );

    my $unknown = link_tools( $dir, 'nobody' );
    is( $unknown->{status}, 255, 'an account that does not exist' );
    like( $unknown->{err}, qr/no such account 'nobody'/, 'named, since it is usually the wrong account rather than a missing home' );

    my $homeless = guest( no_home => 1 );
    my $run      = link_tools( $homeless, 'scratch' );
    is( $run->{status}, 255, 'an account whose home is not there' );
    like( $run->{err}, qr/home directory .* does not exist/, 'named too' );

    my $empty = guest( perls => [] );
    $run = link_tools( $empty, 'scratch' );
    is( $run->{status}, 1, 'and nothing built to link' );
    like( $run->{err}, qr/nothing built under/, 'saying where it looked' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
