#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-garage.t - which garage a guest gets, and when anybody is
asked

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();
use Provisioner::Recipe::garage();

my $GARAGE = 'Provisioner::Recipe::garage';
my $TAGS   = 'https://api.github.com/repos/deuxfleurs-org/garage/tags';

# Newest first, as GitHub lists them, with the kind of tag that must be skipped
# at the front.
my $LIST = '[{"name":"v2.5.0-rc1"},{"name":"v2.4.1"},{"name":"v2.4.0"}]';

# HTTP::Tiny answering from %answers, 599 for anything else, and writing down
# every URL it was asked for.
sub http {
    my (%answers) = @_;
    my @asked;
    my $mock = Test::MockModule->new('HTTP::Tiny');
    $mock->redefine(
        get => sub {
            my ( undef, $url ) = @_;
            push @asked, $url;
            return $answers{$url} // { success => 0, status => 599, content => q{} };
        }
    );
    return ( $mock, \@asked );
}

sub recipe {
    return Provisioner::Cookbook->load( 'garage', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

subtest 'asking what it takes asks nobody' => sub {
    my ( $mock, $asked ) = http();

    my %spec = Provisioner::Cookbook->spec('garage');
    is( $spec{properties}{version}{default}, 'latest', 'the default says what it means rather than what it found' );
    is_deeply( $asked, [], 'and finding it out took no request' );
};

subtest 'latest_version: the newest stable tag on GitHub' => sub {
    local $Provisioner::Recipe::garage::LATEST;
    my ( $mock, $asked ) = http( $TAGS => { success => 1, status => 200, content => $LIST } );

    is( $GARAGE->latest_version, 'v2.4.1', 'not the release candidate ahead of it' );
    is_deeply( $asked, [$TAGS], 'from the tag list' );
};

subtest 'latest_version: the fallback, when GitHub does not answer' => sub {
    local $Provisioner::Recipe::garage::LATEST;
    my ( $mock, $asked ) = http( $TAGS => { success => 1, status => 200, content => 'not json' } );

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };

    is( $GARAGE->latest_version, $Provisioner::Recipe::garage::FALLBACK_VERSION, 'a version that is published' );
    like( "@warned", qr/falling back to \Q$Provisioner::Recipe::garage::FALLBACK_VERSION\E/, 'and says so, since an older garage is otherwise silent' );
};

subtest 'enrich: latest is looked up once, and a version named never is' => sub {
    local $Provisioner::Recipe::garage::LATEST;
    my ( $mock, $asked ) = http( $TAGS => { success => 1, status => 200, content => $LIST } );

    # Two recipes, as two guests in one bin/new_config run are.
    my %first  = recipe()->validate();
    my %second = recipe()->validate();
    is( $first{version},  'v2.4.1', 'latest becomes the release it is' );
    is( $second{version}, 'v2.4.1', 'for every guest' );
    is( scalar @$asked,   1,        'out of one request' );

    @$asked = ();
    my %pinned = recipe()->validate( version => 'v1.3.0' );
    is( $pinned{version}, 'v1.3.0', 'a version named is the version used' );
    is_deeply( $asked, [], 'without asking anybody' );

    like( exception { recipe()->validate( version => '2.4.1' ) }, qr/version/, 'and one that is neither a tag nor latest is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
