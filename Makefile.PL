use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';
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
    'Carp::Always'   => 0,
    'Cwd'            => 0,
    'Fcntl'          => 0,
    'FindBin'        => 0,
    'FindBin::libs'  => 0,
    'File::Path'     => 0,
    'File::Temp'     => 0,
    'URI'            => 0,
    'Config::Simple' => 0,
    'File::Slurper'  => 0,
    'File::Slurper::Temp' => 0,
    'Pod::Usage'     => 0,
    'YAML::XS'       => 0,
    'JSON::PP'       => 0,
    'List::Util'     => 0,
    'Sys::Virt'      => 0,
    'IPC::Run3'      => 0,
    'Net::OpenSSH::More' => 0,
    'Net::EmptyPort'     => 0,
    'parent'             => 0,
    'Term::ReadKey'      => 0,
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

__END__

=head1 NAME

Makefile.PL - build trog-provisioner the ExtUtils::MakeMaker way

=head1 DESCRIPTION

There is a dist.ini beside this, which is what builds a release.  This is here
so the repository can be built and tested with nothing but core tools.

=cut
