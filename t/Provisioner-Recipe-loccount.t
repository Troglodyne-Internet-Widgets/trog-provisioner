#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-loccount.t - which loccount the loccount recipe builds, and with what

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};

use FindBin::libs;

use Provisioner::Cookbook();

my %PROV = (
    template_dirs   => Provisioner::Cookbook->template_dirs('ubuntu'),
    output_dir      => tempdir( CLEANUP => 1 ),
    distro          => 'ubuntu',
    target_packager => 'deb',
);

my %G = (
    domain      => 'build.test.test',
    install_dir => '/opt/domains',
    script_dir  => '/root/bin',
    admin_user  => 'doge',
    user        => 'builder',
);

sub recipe { return Provisioner::Cookbook->load( 'loccount', distro => 'ubuntu' )->new(%PROV) }

subtest 'the version it builds' => sub {
    my %got = recipe()->validated(%G);
    is( $got{version}, '2.28', 'a pinned tag, when the configuration does not say' );

    %got = recipe()->validated( %G, version => '2.27' );
    is( $got{version}, '2.27', 'and the one it names, when it does' );

    ok( exception { recipe()->validated( %G, version => 'master' ) }, 'a branch is refused, because the build is to be the same each time' );
};

# Nothing orders the go target before this one, so the build waits for the
# postrun.
subtest 'the fragment builds that tag after every target' => sub {
    my $said = recipe()->render_global( %G, version => '2.27' );
    ok( index( $said, "/root/bin/queue_postrun_task /root/bin/build_loccount.sh '2.27'\n" ) >= 0, 'it queues the build of the tag as a postrun task' ) or diag $said;
    ok( !recipe()->has_template(),                                                                'and there is no per-domain half' );
};

subtest 'what it needs' => sub {
    my %required = recipe()->required_recipes();
    is_deeply( [ sort keys %required ], ['go'], 'the go recipe, which builds it' );

    my @deps = recipe()->deps();
    ok( ( grep { $_ eq 'python3-ruamel.yaml' } @deps ),                    'ruamel.yaml, because tablegen.py of the build cannot read languages.yaml with PyYAML' );
    ok( ( grep { $_ eq 'git' } @deps ) && ( grep { $_ eq 'make' } @deps ), 'and git and make, which clone and build it' );

    is_deeply( [ recipe()->fetch_hosts() ], [qw{gitlab.com proxy.golang.org}], 'it clones from gitlab.com, and go build fetches its modules from the proxy, which no template says' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
