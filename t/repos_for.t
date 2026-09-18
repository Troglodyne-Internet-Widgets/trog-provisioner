#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

# The script is loaded when the test runs rather than when it compiles, so perl
# sees each of its package variables named once here and calls that a typo.
no warnings qw{once};

=head1 NAME

t/repos_for.t - scripts/repos_for: who it asks, what it keeps between runs, and
what it clones

=cut

use Test::More;
use Capture::Tiny    qw{capture};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use Cwd              qw{getcwd};
use Cpanel::JSON::XS ();

use FindBin;
use FindBin::libs;

my $script = "$FindBin::Bin/../scripts/repos_for";
require_ok($script) or BAIL_OUT("$script does not load; there is nothing to test");

# Clones land in the current directory and the cache under HOME, so both are
# somewhere disposable for the length of this file.
my $home = tempdir( CLEANUP => 1 );
my $work = tempdir( CLEANUP => 1 );
my $was  = getcwd();
chdir $work or BAIL_OUT("Cannot enter $work: $!");

sub row {
    my ( $entity, $name ) = @_;

    return {
        name           => $name,
        clone_url      => "https://api.test/$entity/$name.git",
        ssh_url        => "git\@api.test:$entity/$name.git",
        default_branch => 'main',
    };
}

# One run, with the API answered from a table and every command written down
# rather than run.  A clone that is not named in `fails` makes its directory the
# way a real one would, because the origin rewrite pushd()es into it.
sub repos_for {
    my (%case) = @_;

    my ( @ran, @asked );

    # no_auto: it was loaded from its path above, so there is no module to load.
    my $mock = Test::MockModule->new( 'Trog::repogetter', no_auto => 1 );
    $mock->redefine(
        repos_of => sub {
            my ( $api_url, $entity, $token ) = @_;
            push @asked, [ $api_url, $entity, $token ];
            return @{ $case{repos}{$entity} // [] };
        }
    );
    $mock->redefine(
        run => sub {
            my (@cmd) = @_;
            push @ran, [@cmd];
            return 0       if $case{fails} && "@cmd" =~ $case{fails};
            mkdir $cmd[-1] if $cmd[1] eq 'clone';
            return 1;
        }
    );

    local $ENV{HOME} = $case{home} // $home;

    my $token = $case{token} // "sekrit\n";
    open( my $stdin, '<', \$token ) or die "Cannot open a handle on a string: $!";
    local *STDIN = $stdin;

    my ( $rc, $died );
    my ( $out, $err ) = capture {
        $rc   = eval { Trog::repogetter::main( @{ $case{args} } ) };
        $died = $@;
    };
    close($stdin) or die "Cannot close the token handle: $!";

    return {
        rc    => $rc,
        died  => $died,
        out   => $out,
        err   => $err,
        ran   => \@ran,
        asked => \@asked,
    };
}

sub cloned {
    my ( $result, $name ) = @_;

    return scalar grep { $_->[1] eq 'clone' && $_->[-1] eq $name } @{ $result->{ran} };
}

# The bug this file exists for.  The cache was keyed by api_url alone, so the
# first entity's answer made the second one look already known -- and the second
# was then read out of an entry holding nothing of theirs.
subtest 'a second entity on the same api_url gets its own answer' => sub {
    my $first = repos_for(
        args  => [ 'https://api.test/', 'alice' ],
        repos => { alice => [ row( 'alice', 'alpha' ) ] },
    );
    is( $first->{died}, '', 'the first entity runs' ) or diag $first->{died};
    is( $first->{rc},   0,  'and reports nothing wrong' );
    ok( cloned( $first, 'alpha' ), "alice's repository is cloned" );

    my $second = repos_for(
        args  => [ 'https://api.test/', 'bob' ],
        repos => { bob => [ row( 'bob', 'beta' ) ] },
    );
    is( scalar @{ $second->{asked} }, 1, 'the api is asked about bob' )
      or diag 'the cache answered for bob out of another entity entry';
    ok( cloned( $second, 'beta' ), "bob's repository is cloned" );
};

subtest 'an entity already in the cache is not asked again' => sub {
    my $again = repos_for(
        args  => [ 'https://api.test/', 'alice' ],
        repos => { alice => [ row( 'alice', 'alpha' ) ] },
    );
    is( scalar @{ $again->{asked} }, 0, 'the api is not asked a second time' );
    ok( !cloned( $again, 'alpha' ), 'and a checkout already there is left alone' );
};

subtest '--reset asks again' => sub {
    my $reset = repos_for(
        args  => [qw{--reset https://api.test/ alice}],
        repos => { alice => [ row( 'alice', 'alpha' ) ] },
    );
    is( scalar @{ $reset->{asked} }, 1, 'the api is asked despite the cache' );
};

subtest 'the cache is data rather than perl' => sub {
    open( my $fh, '<', "$home/.repos_for.json" ) or BAIL_OUT("no cache was written: $!");
    my $json = do { local $/; <$fh> };
    close($fh) or die "Cannot close the cache: $!";

    unlike( $json, qr/\$VAR1/, 'nothing that do() would have executed' );
    my $cache = eval { Cpanel::JSON::XS->new->utf8->decode($json) };
    is( ref $cache, 'HASH', 'and it parses as JSON' ) or diag $@;
    ok( exists $cache->{'https://api.test/'}{alice}, 'keyed by url and then entity' );
};

subtest 'a name that is not a plain directory component is refused' => sub {
    my $nasty = repos_for(
        args  => [ 'https://api.test/', 'mallory' ],
        home  => tempdir( CLEANUP => 1 ),
        repos => { mallory => [ row( 'mallory', '../escape' ) ] },
    );
    is( $nasty->{rc}, 1, 'the run reports something wrong' );
    ok( !cloned( $nasty, '../escape' ), 'and nothing is cloned to it' );
    like( $nasty->{err}, qr/not [ ] a [ ] plain [ ] directory [ ] name/x, 'saying which name' );
};

subtest 'an https clone that fails is retried over ssh' => sub {
    my $fallback = repos_for(
        args  => [ 'https://api.test/', 'carol' ],
        home  => tempdir( CLEANUP => 1 ),
        repos => { carol => [ row( 'carol', 'gamma' ) ] },
        fails => qr{https},
    );
    is( $fallback->{rc}, 0, 'the ssh clone carries the run' );
    ok( scalar( grep { $_->[1] eq 'clone' && $_->[2] =~ m{\Agit\@} } @{ $fallback->{ran} } ), 'the ssh url is tried' );
};

subtest 'a token is required, and comes from stdin' => sub {
    my $empty = repos_for(
        args  => [ 'https://api.test/', 'dave' ],
        home  => tempdir( CLEANUP => 1 ),
        token => q{},
    );
    like( $empty->{died}, qr/No [ ] API [ ] token/x, 'an empty stdin is fatal' );

    my $given = repos_for(
        args  => [ 'https://api.test/', 'erin' ],
        home  => tempdir( CLEANUP => 1 ),
        repos => { erin => [ row( 'erin', 'delta' ) ] },
        token => "hunter2\n",
    );
    is( $given->{asked}[0][2], 'hunter2', 'what stdin held reaches the api, without its newline' );
};

# An entity the api answers with nothing is still an entity that was asked.
# Without that recorded, the guard above never fires for one -- so it is fetched
# again every run -- and nothing downstream can tell it from an entity that was
# skipped, which is the whole of what the guest test checks.
subtest 'an entity the api has nothing for is still recorded as asked' => sub {
    my $alone = tempdir( CLEANUP => 1 );

    my $empty = repos_for(
        args  => [ 'https://api.test/', 'frank' ],
        home  => $alone,
        repos => { frank => [] },
    );
    is( $empty->{rc},              0, 'nothing went wrong' );
    is( scalar @{ $empty->{ran} }, 0, 'and nothing was cloned' );

    open( my $fh, '<', "$alone/.repos_for.json" ) or BAIL_OUT("no cache was written: $!");
    my $json = do { local $/; <$fh> };
    close($fh) or die "Cannot close the cache: $!";

    my $cache = Cpanel::JSON::XS->new->utf8->decode($json);
    ok( exists $cache->{'https://api.test/'}{frank}, 'the entity is in the cache with nothing under it' );

    my $again = repos_for(
        args  => [ 'https://api.test/', 'frank' ],
        home  => $alone,
        repos => { frank => [] },
    );
    is( scalar @{ $again->{asked} }, 0, 'and is not asked for a second time' );
};

subtest 'an api that refuses the token stops the run and names the status' => sub {
    my $refusal = bless { code => 401 }, 'FakeResult';
    my $mock    = Test::MockModule->new('Pithub::Repos');
    $mock->redefine( list => sub { return $refusal } );

    my $died = do {
        local $@;
        eval { Trog::repogetter::repos_of(qw{https://api.test/ gina sekrit}); 1 } ? q{} : $@;
    };
    like( $died, qr{https://api\.test/ .* gina .* 401 [ ] Unauthorized}x, 'repos_of dies, naming the api, the entity and the status' );

    $refusal->{code} = 200;
    my @rows = Trog::repogetter::repos_of(qw{https://api.test/ gina sekrit});
    is( scalar @rows, 1, 'and an answer that succeeds gives its rows' );
};

chdir $was or diag "Could not return to $was: $!";

done_testing();

# What Pithub::Repos::list gives back, as far as repos_of reads it: a status,
# and one row when that status is a success.
package FakeResult;

use HTTP::Response ();

sub success {
    my ($self) = @_;
    return $self->{code} == 200;
}

sub response {
    my ($self) = @_;
    return HTTP::Response->new( $self->{code} );
}

sub auto_pagination { return 1 }

## no critic (Subroutines::ProhibitBuiltinHomonyms) -- Pithub::Result calls it next
sub next {
    my ($self) = @_;
    return $self->{given}++ ? undef : { name => 'hotel' };
}
