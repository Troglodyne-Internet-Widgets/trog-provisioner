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
          url  => 'git@github.com:Troglodyne-Internet-Widgets/tCMS.git',
          web  => 'https://github.com/Troglodyne-Internet-Widgets/tCMS',
      },
    },
  },
  PREREQ_PM => {
    'Cwd'            => 0,
    'FindBin'        => 0,
    'Config::Simple' => 0,
    'File::Slurper'  => 0,
    'File::Copy'     => 0,
    'YAML::XS'       => 0,
    'JSON::PP'       => 0,
    'List::Util'     => 0,
    'XML::Twig'      => 0,
    'JSON::MaybeXS'  => 0,
  },
  test => {TESTS => 't/*.t'}
);
