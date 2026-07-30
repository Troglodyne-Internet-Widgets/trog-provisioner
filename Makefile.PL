use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  VERSION   => '0.01',
  META_MERGE        => {
    "meta-spec" => { version => 2 },
    resources => {
      repository => {
          type => 'git',
          url  => 'git@github.com:Troglodyne-Internet-Widgets/provisioners.git',
          web  => 'https://github.com/Troglodyne-Internet-Widgets/provisioners',
      },
    },
  },
  PREREQ_PM => {
    'List::Util'     => 0,
    'FindBin'        => 0,
    'FindBin::libs'  => 0,
    'YAML'           => 0,
    'File::Slurper'  => 0,
    'Config::Simple' => 0,
    'Cwd'            => 0,
    'Clone'          => 0,
    'Text::Xslate'   => 0,
    'Text::Xslate::Bridge::TT2' => 0,
    'Net::SFTP::Foreign'        => 0,
    'File::Path'                => 0,
    'Getopt::Long'              => 0,
    'File::Copy'                => 0,
    'Hash::Merge'               => 0,
    'Net::IP'                   => 0,
    'UUID'                      => 0,
    'Crypt::Digest::SHA512'     => 0,
  },
  TEST_REQUIRES => {
    'Test::More'  => 0,
    'File::Temp'  => 0,
  },
  test => {TESTS => 't/*.t'}
);
