#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/openstack-config.t - Trog::OpenStack::Config: finding clouds.yaml, and picking
a cloud out of it

=cut

use Test::More;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Path();
use File::Slurper::Temp();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what this asserts on
# should not depend on what is deployed on the machine running it.
## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use Trog::OpenStack::Config();

# Every subtest gets a directory of its own and an environment with none of the
# caller's OS_* left in it, so what is being tested is the file and not whatever
# the person running the tests happens to have exported.
my @OS_VARS = qw{
  OS_CLIENT_CONFIG_FILE OS_CLOUD OS_AUTH_URL OS_REGION_NAME
  OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
};

sub clean_env {
    delete @ENV{@OS_VARS};

    # $HOME is one of the places clouds.yaml is looked for, so it has to point
    # somewhere empty rather than at the home directory of whoever is running
    # this -- which may well have a real clouds.yaml in it.
    $ENV{HOME} = tempdir( CLEANUP => 1 );
    return $ENV{HOME};
}

sub write_clouds {
    my ( $path, $content ) = @_;

    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    File::Path::make_path($dir);
    File::Slurper::Temp::write_binary( $path, $content );

    return $path;
}

my $ONE_CLOUD = <<'YAML';
clouds:
  openstack:
    auth:
      auth_url: https://keystone.example.net:5000/v3
      application_credential_id: "abc123"
      application_credential_secret: "shhh"
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
    auth_type: "v3applicationcredential"
YAML

subtest 'a single cloud needs no name' => sub {
    clean_env();
    my $file = write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );

    my $cloud = Trog::OpenStack::Config->load();

    is $cloud->{name},                          'openstack',                            'the only cloud is the one we get';
    is $cloud->{source},                        $file,                                  'and it says where it came from';
    is $cloud->{auth_url},                      'https://keystone.example.net:5000/v3', 'auth_url';
    is $cloud->{application_credential_id},     'abc123',                               'the credential is flattened out of auth';
    is $cloud->{application_credential_secret}, 'shhh',                                 'both halves of it';
    is $cloud->{auth_type},                     'v3applicationcredential',              'auth_type';
    is $cloud->{region_name},                   'RegionOne',                            'region_name';
    is $cloud->{interface},                     'public',                               'interface';
};

subtest 'OS_CLIENT_CONFIG_FILE wins over everything else' => sub {
    clean_env();

    # A file in $HOME that would otherwise be found, so this is testing
    # precedence rather than merely testing that one path works.
    write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );

    my $elsewhere = write_clouds(
        tempdir( CLEANUP => 1 ) . '/somewhere.yaml',
        $ONE_CLOUD =~ s/keystone\.example\.net/other\.example\.net/r
    );
    $ENV{OS_CLIENT_CONFIG_FILE} = $elsewhere;

    my $cloud = Trog::OpenStack::Config->load();
    is $cloud->{source},   $elsewhere,                          'the file we were pointed at';
    is $cloud->{auth_url}, 'https://other.example.net:5000/v3', 'and its contents, not the one in $HOME';
};

subtest 'the installation directory is looked in before $HOME' => sub {
    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );

    my $installed = write_clouds(
        "$ENV{TROG_PROVISIONER_CONFIG}/clouds.yaml",
        $ONE_CLOUD =~ s/keystone\.example\.net/installed\.example\.net/r
    );

    my $cloud = Trog::OpenStack::Config->load();
    is $cloud->{source}, $installed, 'a deployment can carry its own';

    unlink $installed;
};

subtest 'the documented path under $HOME is found too' => sub {
    clean_env();
    my $file = write_clouds( "$ENV{HOME}/.config/openstack/clouds.yaml", $ONE_CLOUD );

    is Trog::OpenStack::Config->load()->{source}, $file, 'and not only the one at the top of $HOME';
};

subtest 'several clouds have to be chosen between' => sub {
    clean_env();
    write_clouds(
        "$ENV{HOME}/clouds.yaml", <<'YAML'
clouds:
  prod:
    auth:
      auth_url: https://prod.example.net:5000/v3
  staging:
    auth:
      auth_url: https://staging.example.net:5000/v3
YAML
    );

    my $err = exception { Trog::OpenStack::Config->load() };
    like $err, qr/more than one cloud/, 'picking one at random is not on offer';
    like $err, qr/prod, staging/,       'and it says what there was to choose from';
    like $err, qr/OS_CLOUD/,            'and how to choose';

    is Trog::OpenStack::Config->load('staging')->{auth_url}, 'https://staging.example.net:5000/v3',
      'naming one works';

    $ENV{OS_CLOUD} = 'prod';
    is Trog::OpenStack::Config->load()->{name}, 'prod', 'and so does OS_CLOUD';
};

subtest 'the environment beats the file for the credential' => sub {
    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );

    $ENV{OS_APPLICATION_CREDENTIAL_ID}     = 'from-env';
    $ENV{OS_APPLICATION_CREDENTIAL_SECRET} = 'also-from-env';
    $ENV{OS_AUTH_URL}                      = 'https://env.example.net:5000/v3';
    $ENV{OS_REGION_NAME}                   = 'RegionTwo';

    my $cloud = Trog::OpenStack::Config->load();
    is $cloud->{application_credential_id},     'from-env',                        'id';
    is $cloud->{application_credential_secret}, 'also-from-env',                   'secret';
    is $cloud->{auth_url},                      'https://env.example.net:5000/v3', 'auth_url';
    is $cloud->{region_name},                   'RegionTwo',                       'region';
};

subtest 'an empty environment variable is not an override' => sub {
    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );

    # An exported-but-empty OS_AUTH_URL is what you get from a sourced openrc
    # that did not set it, and it must not blank out a perfectly good file.
    $ENV{OS_AUTH_URL} = '';

    is Trog::OpenStack::Config->load()->{auth_url}, 'https://keystone.example.net:5000/v3',
      'the file still wins';
};

subtest 'what the errors say' => sub {
    clean_env();
    like exception { Trog::OpenStack::Config->load() }, qr/Could not read clouds\.yaml/,
      'no file at all';
    like exception { Trog::OpenStack::Config->load() }, qr/\Q$ENV{HOME}\E/,
      'and it lists where it looked';

    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", "not: a clouds file\n" );
    like exception { Trog::OpenStack::Config->load() }, qr/no 'clouds' block/,
      'a yaml file that is not a clouds.yaml';

    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", "clouds:\n  openstack:\n    region_name: RegionOne\n" );
    like exception { Trog::OpenStack::Config->load() }, qr/no auth_url/,
      'a cloud with nowhere to authenticate';

    clean_env();
    write_clouds( "$ENV{HOME}/clouds.yaml", $ONE_CLOUD );
    like exception { Trog::OpenStack::Config->load('nope') }, qr/no cloud named 'nope'/,
      'a cloud that is not there';
    like exception { Trog::OpenStack::Config->load('nope') }, qr/openstack/,
      'and it says which one there was';
};

done_testing();
