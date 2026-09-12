package Trog::OpenStack::Config;

#ABSTRACT: clouds.yaml: where a cloud is, and how to log into it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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

F<clouds.yaml> is how the rest of the OpenStack world writes down where a cloud
is and how to log into it: it is what C<python-openstackclient> reads, and what
Horizon hands you when you ask for credentials.  So it is what we read too,
rather than inventing a second file for facts that already have a home.

One cloud comes back as a flat hash.  The file nests the credential under an
C<auth> key and leaves everything else at the top level, which is a distinction
that matters to nobody calling this, so it is flattened away.

=head1 CLASS METHODS

=cut

# Where clouds.yaml is looked for, in order.
#
# OS_CLIENT_CONFIG_FILE first, because that is the variable every other
# OpenStack client honours and somebody who has set it means it.  Then the
# installation's own configuration directory, so a deployment can carry a file
# of its own.  Then the two paths a person's own file lands in -- the documented
# one, and the top of $HOME, which is where you end up if you just saved what
# Horizon gave you.  The system-wide file last.
sub _candidates {
    my @home =
      defined $ENV{HOME} && length $ENV{HOME}
      ? ( "$ENV{HOME}/clouds.yaml", "$ENV{HOME}/.config/openstack/clouds.yaml" )
      : ();

    return grep { defined $_ && length $_ } (
        $ENV{OS_CLIENT_CONFIG_FILE},
        Trog::Config->path('clouds.yaml'),
        @home,
        '/etc/openstack/clouds.yaml',
    );
}

=head2 file

Which F<clouds.yaml> we read, and what was in it.  Returns C<($path, $text)>.

Opens each candidate rather than asking whether it is there first.  A file that
exists and cannot be read is the same problem to us as one that does not exist,
and testing before opening only buys a window for the answer to change.

Dies naming every path it tried, because "no clouds.yaml" is otherwise the least
actionable error this module can produce.

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

The named cloud, as a flat hash reference.

C<$name> defaults to C<$OS_CLOUD>.  Failing that, a file with exactly one cloud
in it needs no name -- there is nothing to choose between.  A file with several
does: picking one at random would be picking one of somebody's production
clouds at random, so that is an error listing what there was to choose from.

The returned hash carries the C<auth> keys (C<auth_url>,
C<application_credential_id>, C<application_credential_secret>, or
C<username>/C<password>) alongside C<auth_type>, C<region_name>, C<interface>
and C<identity_api_version>, plus C<name> and C<source> saying which cloud out
of which file this was.

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
    if ( !defined $name || !length $name ) {
        die "$path defines more than one cloud (" . join( ', ', @names ) . ").\n" . "Say which one, or set OS_CLOUD.\n"
          if @names > 1;
        $name = $names[0];
    }

    my $cloud = $clouds->{$name};
    die "$path has no cloud named '$name'.  It has: " . join( ', ', @names ) . "\n"
      unless ref $cloud eq 'HASH';

    return $class->_flatten( $cloud, $name, $path );
}

# The file's own layout, less the nesting, plus what the environment has to say.
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

    # The environment beats the file for the credential itself.  A CI run gets
    # its secret from somewhere that is not a file on disk, and should not have
    # to rewrite the file to use it.
    my %from_env = (
        auth_url                      => 'OS_AUTH_URL',
        application_credential_id     => 'OS_APPLICATION_CREDENTIAL_ID',
        application_credential_secret => 'OS_APPLICATION_CREDENTIAL_SECRET',
        region_name                   => 'OS_REGION_NAME',
    );
    foreach my $key ( sort keys %from_env ) {
        my $var = $from_env{$key};
        $out{$key} = $ENV{$var} if defined $ENV{$var} && length $ENV{$var};
    }

    die "Cloud '$name' in $path has no auth_url\n"
      unless defined $out{auth_url} && length $out{auth_url};

    return \%out;
}

=head1 SEE ALSO

L<Trog::Config>, for the configuration directory this looks in.

=cut

1;
