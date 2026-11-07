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

# THE SYSTEM PACKAGES in Provisioner::Recipe::tcms.  GitHub is faked: each
# answer is what fetch gives for the next URL that is not cached yet.
subtest 'the packages are those that tCMS declares, and never none' => sub {
    my ( $answer, @asked );
    my $mock = Test::MockModule->new('Provisioner::Recipe::tcms');
    $mock->redefine( fetch => sub { push @asked, $_[1]; return $answer } );
    my $recipe = Provisioner::Cookbook->load( 'tcms', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => '/nonexistent',
        distro        => 'ubuntu',
    );
    my $branch = 0;
    my $deps   = sub {
        my ($content) = @_;
        $branch++;
        $answer = ref $content ? $content : { success => 1, status => 200, reason => 'OK', content => $content };
        return $recipe->deps( repo_branch => "b$branch" );
    };

    is_deeply( [ $deps->("x_system_packages:\n  File::LibMagic:\n    deb: libmagic-dev\n  Gpp:\n    deb: g++\n    rpm: gcc-c++\n") ], [qw{git libmagic-dev g++}], 'git, which the recipe clones with, and the deb package of each dependency, on Ubuntu' );
    is( $asked[-1], 'https://raw.githubusercontent.com/Troglodyne-Internet-Widgets/tCMS/b1/metamerge.yml', 'read from the branch of the repository' );
    $recipe->deps( repo_branch => 'b1' ) for 1 .. 2;
    is( scalar @asked, 1, 'once for each branch' );
    $recipe->deps( repo_branch => 'b1', repo_url => 'https://github.com/test-org/tCMS-fork' );
    is( $asked[-1], 'https://raw.githubusercontent.com/test-org/tCMS-fork/b1/metamerge.yml', 'and of each repository' );

    my %dies = (
        'GitHub does not answer'                 => [ { success => 0, status => 599, reason => 'Internal Exception', content => "Could not connect\n" }, qr/could[ ]not[ ]read\N*599\N*Could[ ]not[ ]connect/ ],
        'GitHub fails'                           => [ { success => 0, status => 503, reason => 'Service Unavailable' },                                  qr/could[ ]not[ ]read\N*503[ ]Service/ ],
        'the repository has no file'             => [ { success => 0, status => 404, reason => 'Not Found' },                                            qr/is[ ]not[ ]there\N*declares[ ]no[ ]system[ ]packages/ ],
        'the file does not parse'                => [ "x_system_packages: [\n",                                                                          qr/system[ ]packages[ ]of[ ]tCMS/ ],
        'the declaration is not valid'           => [ "x_system_packages:\n  FFmpeg:\n    deb: ffmpeg-\n",                                               qr/metamerge[.]yml[ ]is[ ]not[ ]valid/ ],
        'it declares nothing'                    => [ "name: tCMS\n",                                                                                    qr/declares[ ]no[ ]system[ ]packages/ ],
        'a dependency has only another packager' => [ "x_system_packages:\n  File::LibMagic:\n    rpm: file-devel\n  Gpp:\n    deb: g++\n",              qr/for[ ]File::LibMagic,/ ],
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

    like( exception { $recipe->deps( repo_url => 'https://bogus.test.test/x/tCMS' ) },                                                                                qr/not[ ]a[ ]repository[ ]on[ ]GitHub/, 'a repository that is not on GitHub is refused' );
    like( exception { $recipe->validate( domain => 'web.test.test', install_dir => '/bogus', admin_user => 'bogus', repo_url => 'https://bogus.test.test/x/tCMS' ) }, qr{/repo_url},                          'and so by the schema' );
    is_deeply( [ $recipe->fetch_hosts( repo_url => 'https://github.com/test-org/tCMS-fork' ) ], [qw{github.com raw.githubusercontent.com cdn.jsdelivr.net}], 'the guest clones it from GitHub, and fetches the front-end files of prereq-frontend' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
