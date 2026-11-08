#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-tcms.t - tCMS sends its log to syslog through tpsgi, and declares its packages

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use File::Which();
use IPC::Run3();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

subtest 'tpsgi is told to add the syslog output of tCMS' => sub {
    my %required = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->required_recipes( domain => 'web.test.test', install_dir => '/bogus' );
    my %tpsgi    = $required{tpsgi}->( domain => 'web.test.test', install_dir => '/bogus' );

    # The tpsgi jail reads tpsgi.log, and nothing ships a file.  So the same
    # lines go to syslog too, which logshipper forwards.
    is_deeply( $tpsgi{loggers}, ['Trog::Log::Syslog'], 'the logger that tCMS ships' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'tpsgi', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $recipe->generate_files( $dir, domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', user => 'bogus', %tpsgi );
    like( File::Slurper::read_text("$dir/tpsgi.ini"), qr/^loggers[ ]=[ ]Trog::Log::Syslog$/m, 'and tpsgi.ini names it' );
    like( File::Slurper::read_text("$dir/tpsgi.ini"), qr/^basedir=tCMS$/m,                    'and tPSGI changes into the checkout of tCMS' );
};

# THE JOB WORKER in Provisioner::Recipe::tcms.
subtest 'the job worker is a unit that starts after tPSGI and restarts on failure' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    my %base = ( domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', user => 'bogus', admin_user => 'bogusadmin' );

    is( { $recipe->validate(%base) }->{worker_jobs}, 1, 'one job at a time unless the configuration says more' );
    isnt( exception { $recipe->validate( %base, worker_jobs => 0 ) }, undef, 'and a worker that runs no job is refused' );

    $recipe->generate_files( $dir, %base, worker_jobs => 2 );
    my $unit = File::Slurper::read_text("$dir/tcms-worker.service");
    like( $unit, qr{^User=bogus$}m,                                     'it runs as the service user' );
    like( $unit, qr{^WorkingDirectory=/bogus/web[.]test[.]test/tCMS$}m, 'in the checkout' );
    my $perl   = qr{^ExecStart=\S*/perl[ ]bin/tcms-jobs}m;
    my $worker = qr{[ ]minion[ ]worker[ ]-j[ ]2$}m;
    like( $unit, qr{$perl$worker},                              'with the worker command of tCMS and the configured jobs' );
    like( $unit, qr{^After=.*\bweb[.]test[.]test[.]service\b}m, 'after the service of tPSGI' );
    like( $unit, qr{^Restart=on-failure$}m,                     'and restarts on failure' );
};

# A SITE BEHIND A RELAY in Provisioner::Recipe::tcms.
subtest 'a secure host is written by tCMS, after the perl target' => sub {

    # A recipe for each render, since validated() keeps the first options that it is given.
    my $recipe = sub {
        return Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->new(
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => tempdir( CLEANUP => 1 ),
            distro        => 'ubuntu',
        );
    };
    my %base     = ( domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', user => 'bogus', admin_user => 'bogusadmin' );
    my $hostname = sub (%opts) {
        return grep { m/tcms-hostname/ } Provisioner::Recipe->fragment_commands( $recipe->()->render( %base, %opts ) );
    };

    is( scalar $hostname->(), 0, 'without one, the recipe leaves the hosts of tCMS alone' );

    my @set = $hostname->( secure_host => 'secure.web.test.test' );
    is( scalar @set, 1, 'with one, it sets them once' );
    like( $set[0], qr{^\S*/queue_postrun_task[ ]}, 'in a task that runs after every target, the perl target among them' );
    like( $set[0], qr{sudo[ ]-u[ ]bogus[ ]},       'as the service user' );
    my $hosts = qr{[ ]'secure[.]web[.]test[.]test'[ ]'web[.]test[.]test'}x;
    like( $set[0], qr{bin/tcms-hostname[ ]--secure$hosts}, 'with the secure host, and the domain as the hostname' );

    isnt( exception { $recipe->()->validate( %base, secure_host => 'not a host' ) }, undef, 'and a secure host that is not a host name is refused' );
};

# THE SYSTEM PACKAGES in Provisioner::Recipe::tcms.  git is faked: each answer
# is what fetch gives for the next repository and branch that is not cached yet,
# the content of metamerge.yml, undef for none, or a code reference that dies.
subtest 'the packages are those that tCMS declares, and never none' => sub {
    my ( $answer, @asked );
    my $mock = Test::MockModule->new('Provisioner::Recipe::tcms');
    $mock->redefine( fetch => sub { push @asked, "$_[2] of $_[1]"; return ref $answer ? $answer->() : $answer } );
    my $recipe = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => '/nonexistent',
        distro        => 'ubuntu',
    );
    my $branch = 0;
    my $deps   = sub {
        my ($content) = @_;
        $branch++;
        $answer = $content;
        return $recipe->deps( repo_branch => "b$branch" );
    };

    is_deeply( [ $deps->("x_system_packages:\n  File::LibMagic:\n    deb: libmagic-dev\n  Gpp:\n    deb: g++\n    rpm: gcc-c++\n") ], [qw{git libmagic-dev g++}], 'git, which the recipe clones with, and the deb package of each dependency, on Ubuntu' );
    is( $asked[-1], 'b1 of https://github.com/Troglodyne-Internet-Widgets/tCMS.git', 'read from the branch of the repository' );
    $recipe->deps( repo_branch => 'b1' ) for 1 .. 2;
    is( scalar @asked, 1, 'once for each branch' );
    $recipe->deps( repo_branch => 'b1', repo_url => 'https://git.test.test/test-org/tCMS-fork' );
    is( $asked[-1], 'b1 of https://git.test.test/test-org/tCMS-fork', 'and of each repository, on any host' );

    my $cloned = qr/could[ ]not[ ]clone/;
    my $none   = qr/there[ ]is[ ]no[ ]metamerge[.]yml/;
    my %dies   = (
        'git cannot clone'                       => [ sub { die "tcms: could not clone b of x: fatal: repository not found\n" },            qr/$cloned\N*repository[ ]not[ ]found/ ],
        'the branch has no file'                 => [ undef,                                                                                qr/$none\N*declares[ ]no[ ]system[ ]packages/ ],
        'the file does not parse'                => [ "x_system_packages: [\n",                                                             qr/system[ ]packages[ ]of[ ]tCMS/ ],
        'the declaration is not valid'           => [ "x_system_packages:\n  FFmpeg:\n    deb: ffmpeg-\n",                                  qr/metamerge[.]yml[ ]is[ ]not[ ]valid/ ],
        'it declares nothing'                    => [ "name: tCMS\n",                                                                       qr/declares[ ]no[ ]system[ ]packages/ ],
        'a dependency has only another packager' => [ "x_system_packages:\n  File::LibMagic:\n    rpm: file-devel\n  Gpp:\n    deb: g++\n", qr/for[ ]File::LibMagic,/ ],
    );
    foreach my $case ( sort keys %dies ) {
        like( exception { $deps->( $dies{$case}[0] ) }, $dies{$case}[1], "when $case, the generation stops and says so" );
    }

    # A name and an archive for a release, resolved for the release of the domain.
    my $declaration = <<'YAML';
x_system_packages:
  File::LibMagic:
    deb: libmagic-dev
  Legacy:
    deb:
      name: legacy-dev
      ubuntu/26.04: ~
  OpenSSL:
    deb:
      name: libssl3
      ubuntu/24.04: libssl3t64
  Vendor:
    deb:
      name: vendor-tool
      source: vendor
    test: vendor-tool --version
x_system_sources:
  deb:
    - name: vendor
      uri: https://archive.test.test/apt
      suites: ['{codename}']
      components: [main]
      key: https://archive.test.test/key.asc
      fingerprint: 0123456789abcdef0123456789abcdef01234567
YAML
    is_deeply( [ $deps->($declaration) ], [qw{git libmagic-dev legacy-dev libssl3t64 vendor-tool}], 'the name of each package for the pinned release' );
    is_deeply(
        [ $recipe->package_sources( repo_branch => "b$branch" ) ],
        [ { name => 'vendor', uri => 'https://archive.test.test/apt', suites => ['noble'], components => ['main'], key => 'https://archive.test.test/key.asc', fingerprint => '0123456789abcdef0123456789abcdef01234567' } ],
        'and the archive of one of them, for the codename of the release, with the fingerprint of its key'
    );
    is_deeply( [ $recipe->deps( repo_branch => "b$branch", distro_release => 'resolute' ) ],                                 [qw{git libmagic-dev libssl3 vendor-tool}], 'another release gets the name of every other, and none for a dependency that it needs no package for' );
    is_deeply( [ map { $_->{suites} } $recipe->package_sources( repo_branch => "b$branch", distro_release => 'resolute' ) ], [ ['resolute'] ],                           'and the archive for its own codename' );
    is( scalar @asked, $branch + 1, 'from the declaration that was read once' );

    my $validate = sub ($url) {
        return exception { $recipe->validate( domain => 'web.test.test', install_dir => '/bogus', admin_user => 'bogus', repo_url => $url ) }
    };
    foreach my $url (qw{https://git.test.test/x/tCMS.git ssh://git@git.test.test/x/tCMS.git git@git.test.test:x/tCMS.git file:///bogus/tCMS.git}) {
        is( $validate->($url), undef, "the schema takes $url" );
    }
    like( $validate->('git.test.test/x/tCMS'), qr{/repo_url:\ is\ not\ a\ git\ remote}, 'and refuses what is not a git remote, and says so' );
    is_deeply( [ $recipe->fetch_hosts( repo_url => 'https://github.com/test-org/tCMS-fork' ) ], [qw{github.com raw.githubusercontent.com cdn.jsdelivr.net}], 'the guest clones it from GitHub, and fetches the front-end files of prereq-frontend' );
};

# fetch itself, against a repository here, by file://, as git reads any other.
subtest 'fetch reads metamerge.yml from a branch of a git repository' => sub {
    my $git = File::Which::which('git');
    plan skip_all => 'no git here' unless $git;

    # A hook sets GIT_DIR and GIT_INDEX_FILE, which git obeys over -C.
    IPC::Run3::run3( [ $git, qw{rev-parse --local-env-vars} ], \undef, \my $vars, \undef );
    my @local = split m/\n/, $vars;
    local @ENV{@local};
    delete @ENV{@local};

    my $work = tempdir( CLEANUP => 1 );
    my $run  = sub (@args) {
        IPC::Run3::run3( [ $git, '-C', $work, @args ], \undef, \my $out, \my $err );
        die "git @args: $err" if $?;
        return $out;
    };
    $run->(qw{init --quiet --initial-branch=main});
    File::Slurper::Temp::write_text( "$work/metamerge.yml", "x_system_packages:\n  Gpp:\n    deb: g++\n" );
    File::Slurper::Temp::write_text( "$work/other",         "a file of another name\n" );
    $run->(qw{add metamerge.yml other});
    $run->(qw{-c user.name=Test -c user.email=test@test.test commit --quiet -m one});
    $run->(qw{checkout --quiet -b bare});
    $run->(qw{rm --quiet metamerge.yml});
    $run->(qw{-c user.name=Test -c user.email=test@test.test commit --quiet -m two});

    my $recipe = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' );
    is( $recipe->fetch( "file://$work", 'main' ), "x_system_packages:\n  Gpp:\n    deb: g++\n", 'the file on the branch' );
    is( $recipe->fetch( "file://$work", 'bare' ), undef,                                        'and none on a branch that has none' );
    like( exception { $recipe->fetch( "file://$work", 'nowhere' ) }, qr/could[ ]not[ ]clone[ ]nowhere[ ]of[ ]file:/, 'and a branch that is not there stops it' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
