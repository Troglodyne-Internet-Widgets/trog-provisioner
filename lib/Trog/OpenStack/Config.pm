package Trog::OpenStack::Config;

#ABSTRACT: clouds.yaml: where a cloud is, and how to log into it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Slurper();
use YAML::XS();

use Trog::Config();

=head1 NAME

Trog::OpenStack::Config - clouds.yaml: where a cloud is, and how to log into it

=head1 SYNOPSIS

    use Trog::OpenStack::Config();

    # The cloud named by $OS_CLOUD, or the only one in the file
    my $cloud = Trog::OpenStack::Config->load();

    # Or a particular one
    $cloud = Trog::OpenStack::Config->load('openstack');

    $cloud->{auth_url};
    $cloud->{application_credential_id};

=head1 DESCRIPTION

Other OpenStack tools keep the location of a cloud and its login in
F<clouds.yaml>.  C<python-openstackclient> reads it, and Horizon gives it to you
when you ask for credentials.  This module reads the same file, so these facts
are in one file only.

A cloud comes back as a flat hash.  The file puts the credential under an
C<auth> key and the rest at the top level.  No caller needs that difference, so
the hash has one level.

=head1 CLASS METHODS

=cut

=head2 _candidates

Returns the paths where F<clouds.yaml> can be, in the order to try them:

=over 4

=item 1.

C<$OS_CLIENT_CONFIG_FILE>.  Every other OpenStack client obeys it, so a person
who sets it wants it.

=item 2.

F<clouds.yaml> in the configuration directory of L<Trog::Config>, so that an
installation can have its own file.

=item 3.

F<$HOME/clouds.yaml>, where a file that you save from Horizon usually goes.

=item 4.

F<$HOME/.config/openstack/clouds.yaml>, the documented location for your own
file.

=item 5.

F</etc/openstack/clouds.yaml>, the file for the whole system.

=back

=cut

sub _candidates {
    my @home =
      $ENV{HOME}
      ? ( "$ENV{HOME}/clouds.yaml", "$ENV{HOME}/.config/openstack/clouds.yaml" )
      : ();

    return grep { $_ } (
        $ENV{OS_CLIENT_CONFIG_FILE},
        Trog::Config->path('clouds.yaml'),
        @home,
        '/etc/openstack/clouds.yaml',
    );
}

=head2 file

Returns C<($path, $text)>: the first F<clouds.yaml> that it can read, and its
contents.

It opens each path and does not first test if the file exists.  A file that it
cannot read is the same problem as a file that is not there.  Also, a test
before the open gives the file time to change.

Dies with a list of each path that it tried, because "no clouds.yaml" alone does
not tell you what to fix.

=cut

sub file {
    my ($class) = @_;

    my @tried = $class->_candidates;
    foreach my $path (@tried) {
        my $text = eval { File::Slurper::read_binary($path) };
        return ( $path, $text ) if defined $text;
    }

    die "Could not read clouds.yaml.  Looked in:\n" . join( '', map { "    $_\n" } @tried );
}

=head2 load($name)

Returns the cloud named C<$name>, as a flat hash reference.

The default for C<$name> is C<$OS_CLOUD>.  If neither is set, a file with one
cloud needs no name.  A file with more than one cloud is an error that lists
them.  A random choice can pick a production cloud.

The hash holds the keys from C<auth>: C<auth_url>,
C<application_credential_id> and C<application_credential_secret>, or
C<username> and C<password>.  It also holds C<auth_type> (default
C<password>), C<region_name>, C<interface> (default C<public>) and
C<identity_api_version> (default 3).  C<name> and C<source> give the cloud and
the file that it came from.

A non-empty C<$OS_AUTH_URL>, C<$OS_APPLICATION_CREDENTIAL_ID>,
C<$OS_APPLICATION_CREDENTIAL_SECRET> or C<$OS_REGION_NAME> replaces the value
from the file.

Dies when no file can be read or parsed, when the file has no clouds, when the
cloud is not there or cannot be chosen, and when it has no C<auth_url>.

=cut

sub load {
    my ( $class, $name ) = @_;

    my ( $path, $text ) = $class->file;

    my $parsed = eval { YAML::XS::Load($text) };
    die "Could not parse $path: $@" if $@;

    my $clouds = ref $parsed eq 'HASH' ? $parsed->{clouds} : undef;
    die "$path has no 'clouds' block, so it is not a clouds.yaml\n"
      unless ref $clouds eq 'HASH';

    my @names = sort keys %$clouds;
    die "$path defines no clouds\n" unless @names;

    $name //= $ENV{OS_CLOUD};
    if ( !$name ) {
        die "$path defines more than one cloud (" . join( ', ', @names ) . ").\n" . "Say which one, or set OS_CLOUD.\n"
          if @names > 1;
        $name = $names[0];
    }

    my $cloud = $clouds->{$name};
    die "$path has no cloud named '$name'.  It has: " . join( ', ', @names ) . "\n"
      unless ref $cloud eq 'HASH';

    return $class->_flatten( $cloud, $name, $path );
}

=head2 _flatten($cloud, $name, $path)

Returns C<$cloud> as the hash that C<load> describes.

=cut

sub _flatten {
    my ( $class, $cloud, $name, $path ) = @_;

    my $auth = ref $cloud->{auth} eq 'HASH' ? $cloud->{auth} : {};

    my %out = (
        %$auth,
        name                 => $name,
        source               => $path,
        auth_type            => $cloud->{auth_type}            // 'password',
        interface            => $cloud->{interface}            // 'public',
        identity_api_version => $cloud->{identity_api_version} // 3,
        region_name          => $cloud->{region_name},
    );

    # The environment wins over the file, so that a CI run that gets its
    # secret from elsewhere does not have to change the file.
    my %from_env = (
        auth_url                      => 'OS_AUTH_URL',
        application_credential_id     => 'OS_APPLICATION_CREDENTIAL_ID',
        application_credential_secret => 'OS_APPLICATION_CREDENTIAL_SECRET',
        region_name                   => 'OS_REGION_NAME',
    );
    foreach my $key ( sort keys %from_env ) {
        my $var = $from_env{$key};
        $out{$key} = $ENV{$var} if length $ENV{$var};    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a secret of "0" is still a secret
    }

    die "Cloud '$name' in $path has no auth_url\n"
      unless $out{auth_url};

    return \%out;
}

=head1 SEE ALSO

L<Trog::Config>, for the configuration directory this looks in.

=cut

1;
