use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME      => 'Trog::HV',
  VERSION   => '0.01',
  META_MERGE        => {
    "meta-spec" => { version => 2 },
    resources => {
      repository => {
          type => 'git',
          url  => 'git@github.com:Troglodyne-Internet-Widgets/trog-provisioner.git',
          web  => 'https://github.com/Troglodyne-Internet-Widgets/trog-provisioner',
      },
    },
  },
  PREREQ_PM => {
    'Cwd'            => 0,
    'Fcntl'          => 0,
    'FindBin'        => 0,
    'FindBin::libs'  => 0,
    'File::Path'     => 0,
    'File::Temp'     => 0,
    'URI'            => 0,
    'Config::Simple' => 0,
    'File::Slurper'  => 0,
    'File::Copy'     => 0,
    'Pod::Usage'     => 0,
    'YAML::XS'       => 0,
    'JSON::PP'       => 0,
    'List::Util'     => 0,
    'XML::Twig'      => 0,
    'JSON::MaybeXS'  => 0,
    'Sys::Virt'      => 0,
    'Net::OpenSSH::More' => 0,
    'Net::EmptyPort'     => 0,
  },
  # Only needed to lint this repo, not to run it.
  TEST_REQUIRES => {
    'Test::More'        => 0,
    'Test::MockModule'  => 0,
    'Perl::Critic' => 0,
    'Perl::Critic::Policy::ProhibitUseLib'              => 0,
    'Perl::Critic::Policy::ProhibitUsageSubs'           => 0,
    'Perl::Critic::Policy::RequireQwForLiteralLists'    => 0,
    'Perl::Critic::Policy::ProhibitNoWarningsRedefine'  => 0,
    'Perl::Critic::Policy::RequireFatalWarnings'        => 0,
    'Perl::Critic::Policy::ProhibitUnusedImports'       => 0,
  },
  test => {TESTS => 't/*.t'}
);
