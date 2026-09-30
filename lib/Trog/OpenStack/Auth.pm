package Trog::OpenStack::Auth;

#ABSTRACT: Keystone v3 application credentials, and the token that comes back.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent 'OpenStack::Client::Auth::v3';

use Cpanel::JSON::XS();
use Digest::SHA();
use File::Path();
use File::Slurper();
use File::Slurper::Temp();
use OpenStack::Client();
use Time::Piece();

use Trog::Config();
use Trog::Credentials();
use Trog::OpenStack::Config();
use Trog::Secrets();

# Only a string below names this class, but it must be loaded, because
# OpenStack::Client calls new() on that name.
use Trog::OpenStack::UserAgent();    ## no critic (ProhibitUnusedImports)

=head1 NAME

Trog::OpenStack::Auth - Keystone v3 application credentials, and the token that
comes back

=head1 SYNOPSIS

    use Trog::OpenStack::Auth();

    # From clouds.yaml
    my $auth = Trog::OpenStack::Auth->from_cloud();
    my $auth = Trog::OpenStack::Auth->from_cloud('openstack');

    # Or spelled out
    $auth = Trog::OpenStack::Auth->new(
        'https://keystone.example.net:5000/v3',
        application_credential_id     => '...',
        application_credential_secret => '...',
    );

    my $nova = $auth->service('compute', region => 'RegionOne');

    # And what it is for
    my $api = OpenStack::MetaAPI->new({auth => $auth});

=head1 DESCRIPTION

L<OpenStack::Client::Auth::v3> authenticates in one way only.  It puts
C<methods =E<gt> ['password']> in the request, and it dies without a password.
An application credential has no username and no password.  It is an id and a
secret that Keystone issues, for one project.  So the parent has nothing to
send.

This module sends the application credential request instead.  After the token
arrives, the parent does the work.  C<service> finds a service type in the
catalog and returns an L<OpenStack::Client> for it.  C<services> lists the
service types in the catalog.  This module replaces only C<token>.  See
L</token>.

=head2 The token cache

Each command that uses the cloud has to authenticate, which is a round trip to
Keystone.  The cache removes that round trip.

The module uses a cached token until C<$EXPIRY_MARGIN> seconds before the
C<expires_at> that Keystone put in it.  It does not ask the cloud whether the
token is still good.  The token already holds the answer, so no extra request
is necessary.  Also, a token cannot pass a check and then expire during the run.

The cache key is the endpoint and the credential id together.  A second cloud,
or the same cloud with a new credential, does not read the token of the first.
The file holds a bearer credential.  Its mode is 0600, in a directory of mode
0700.

=head1 CLASS METHODS

=cut

# Seconds before expiry that a cached token stops being used, because a
# provision takes minutes and must not fail halfway through.
our $EXPIRY_MARGIN = 300;

=head2 from_cloud($name, %args)

Authenticates against a cloud from F<clouds.yaml>, and returns a new object.
C<$name> goes to L<Trog::OpenStack::Config/load>, so the default is
C<$OS_CLOUD>, or the only cloud in the file.  C<%args> goes to C<new>, after
the values from the file, so it overrides them.

Dies with the name of the cloud when its C<auth_type> is not
C<v3applicationcredential>.  It also dies for each reason that C<load> and
C<new> die.

The secret can be in F<secrets.kdbx> instead of in F<clouds.yaml>.  Write it as
a reference, in the same way that a recipe writes one:

    auth:
      application_credential_id: 0123abcd
      application_credential_secret: secret:openstack/credential/password

The module looks up the secret only when it must ask Keystone for a token.  A
run that finds a cached token does not ask for the passphrase of the database.
Other runs ask for it one time, under the name C<keepass>.  Everything else in
this repository uses that name for it too.

=cut

sub from_cloud {
    my ( $class, $name, %args ) = @_;

    my $cloud = Trog::OpenStack::Config->load($name);

    die "Cloud '$cloud->{name}' in $cloud->{source} authenticates with '$cloud->{auth_type}'.\n" . "This only speaks v3applicationcredential.\n"
      unless $cloud->{auth_type} eq 'v3applicationcredential';

    my $secret = $class->secret_for($cloud);

    return $class->new(
        $cloud->{auth_url},
        application_credential_id     => $cloud->{application_credential_id},
        application_credential_secret => $secret,
        region                        => $cloud->{region_name},
        interface                     => $cloud->{interface},
        %args,
    );
}

=head2 new($endpoint, %args)

Returns an object that holds a token, from the cache or from Keystone.  A
token from Keystone goes into the cache for the next command.  A cache that
cannot be written is not an error, because it only makes the next run slower.

C<$endpoint> is the Keystone endpoint, with or without C</v3> at the end.

C<application_credential_id> and C<application_credential_secret> are
required.  The secret can be a code reference.  The module calls it only when
the cache has no token to give.

These are optional:

=over 4

=item *

C<region> and C<interface>.  The object keeps them, and the methods C<region>
and C<interface> return them.  C<service> does not use them.  The caller passes
them to it.

=item *

C<cache_dir>, the directory of the cache.  C<no_cache> turns the cache off.

=item *

C<package_ua>, C<package_request> and C<package_response>, as
L<OpenStack::Client> takes them.

=back

The default C<package_ua> is L<Trog::OpenStack::UserAgent>, not
L<LWP::UserAgent>.  With L<LWP::UserAgent>, L<OpenStack::Client> turns off the
TLS hostname check, and the token goes over that connection.

Dies when C<$endpoint>, the id or the secret is missing.  Also dies when
Keystone does not give a token and a service catalog.

=cut

sub new {
    my ( $class, $endpoint, %args ) = @_;

    die "No Keystone endpoint provided\n" unless $endpoint;

    my $id     = $args{application_credential_id};
    my $secret = $args{application_credential_secret};

    die "No application credential id provided in \"application_credential_id\"\n"
      unless $id;
    die "No application credential secret provided in \"application_credential_secret\"\n"
      unless ref $secret eq 'CODE' || length $secret;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a secret of "0" is still a secret

    # The auth_url in a clouds.yaml can end in /v3 or not: Horizon adds it, and
    # openstacksdk documents both forms.  OpenStack::Client adds its paths to
    # the end of the endpoint, and each form must get to /v3/auth/tokens.
    $endpoint =~ s{/+$}{};
    $endpoint .= '/v3' unless $endpoint =~ m{/v3$};

    my $self = bless {
        package_ua       => $args{package_ua} // 'Trog::OpenStack::UserAgent',
        package_request  => $args{package_request},
        package_response => $args{package_response},
        clients          => {},
        services         => [],
        endpoint         => $endpoint,
        region           => $args{region},
        interface        => $args{interface},
        credential_id    => $id,
        cache_dir        => $args{cache_dir},
        no_cache         => $args{no_cache},
    }, $class;

    my $path = $self->{no_cache} ? undef : $self->cache_path;

    # A bad or missing cache file is a cache miss, and costs only a round trip.
    my $cached;
    $cached = eval { Cpanel::JSON::XS::decode_json( File::Slurper::read_binary($path) ) } if defined $path;
    $cached = {} unless ref $cached eq 'HASH';

    # Keystone reports UTC, which is what strptime assumes.  An expiry that
    # cannot be read is taken as expired.
    my ($stamp) = ( $cached->{expires_at} // q{} ) =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/;
    my $expires = 0;
    $expires = eval { Time::Piece->strptime( $stamp, '%Y-%m-%dT%H:%M:%S' )->epoch } // 0 if defined $stamp;

    # The cache key holds the endpoint too, but a file with a colliding name
    # must not send a token to the wrong cloud.
    if (   $cached->{token}
        && ref $cached->{catalog} eq 'ARRAY'
        && @{ $cached->{catalog} }
        && ( $cached->{endpoint} // q{} ) eq $endpoint
        && $expires - $EXPIRY_MARGIN > time() ) {
        $self->{token}      = $cached->{token};
        $self->{expires_at} = $cached->{expires_at};
        $self->{services}   = $cached->{catalog};
        return $self;
    }

    my ( $response, $body );
    my $ok = eval {
        my $client = OpenStack::Client->new(
            $endpoint,
            package_ua       => $self->{package_ua},
            package_request  => $self->{package_request},
            package_response => $self->{package_response},
        );

        $response = $client->request(
            method => 'POST',
            path   => '/auth/tokens',
            body   => {
                auth => {
                    identity => {
                        methods                => ['application_credential'],
                        application_credential => {
                            id     => $id,
                            secret => ref $secret eq 'CODE' ? $secret->() : $secret,
                        },
                    },
                },
            },
        );

        $body = $response->decode_json;
        1;
    };

    # Each step of the exchange can fail, and each failure must name the
    # endpoint.  Usually decode_json fails, with the body of a 4xx as its
    # message.  "401 Unauthorized" alone does not tell a revoked credential
    # from the wrong cloud, and each has a different fix.
    die "Authenticating against $endpoint failed: $@" unless $ok;

    my $token = $response->header('X-Subject-Token');
    die "Authenticating against $endpoint returned no token\n"
      unless $token;

    my $catalog = $body->{token}{catalog};
    die "Authenticating against $endpoint returned no service catalog\n"
      unless ref $catalog eq 'ARRAY' && @$catalog;

    $self->{response}   = $response;
    $self->{body}       = $body;
    $self->{token}      = $token;
    $self->{expires_at} = $body->{token}{expires_at};
    $self->{services}   = $catalog;

    return $self unless defined $path;

    my $encoded = Cpanel::JSON::XS::encode_json(
        {
            token      => $token,
            expires_at => $self->{expires_at},
            catalog    => $catalog,
            endpoint   => $endpoint,
        }
    );

    eval {
        my ($dir) = $path =~ m{^(\N*)/[^/]+$};
        File::Path::make_path( $dir, { mode => 0o700 } );

        # write_binary renames a temporary file over $path, so that two
        # provisions at once cannot leave a half-written file.  It takes the
        # mode of that temporary file from this package variable, so no other
        # user can read the token, even before the rename.
        local $File::Slurper::Temp::FILE_TEMP_PERMS = 0o600;
        File::Slurper::Temp::write_binary( $path, $encoded );
        1;
    } or return $self;

    return $self;
}

=head2 secret_for($cloud)

Returns the application credential secret of C<$cloud>, which is a cloud as
L<Trog::OpenStack::Config/load> returns one.  A secret written out is itself.
A C<secret:> reference comes back as a code reference that fetches it from
F<secrets.kdbx> when it is called, so a run that never asks Keystone for a
token never opens the store.  Dies at once when the reference is malformed.

F<bin/openstack-env> calls it and then the code reference, to hand the secret
to the tools that read F<clouds.yaml> and have no idea what a reference is.

=cut

sub secret_for {
    my ( $class, $cloud ) = @_;

    my $secret = $cloud->{application_credential_secret};
    return $secret unless defined $secret && index( $secret, 'secret:' ) == 0;

    # Parsed now, so that a malformed reference fails every run, not only the
    # runs whose token has expired.
    Trog::Secrets->parse($secret);

    return sub {
        my %found = Trog::Secrets->lookup( Trog::Config->path('secrets.kdbx'), Trog::Credentials->prompt( 'Enter password:', 'keepass' ), secret => $secret );
        return $found{secret};
    };
}

=head1 OBJECT METHODS

=head2 token

Returns the Keystone token, in the form that C<X-Auth-Token> takes.

This replaces the method of the parent, which reads the token from the headers
of the HTTP response.  A token from the cache has no response.

=head2 region, interface

Return the values that went to C<new>, for a caller that makes the options
for C<service>.

=cut

sub token     ($self) { return $self->{token} }
sub region    ($self) { return $self->{region} }
sub interface ($self) { return $self->{interface} }

=head1 THE CACHE

=head2 cache_path

Returns the path of the cache file for the token of this object.  It is in
C<cache_dir>, or else in F<trog-provisioner> under C<$XDG_CACHE_HOME> or under
F<$HOME/.cache>.  Returns nothing when there is no directory for the cache,
which is when none of those is set.

=cut

sub cache_path {
    my ($self) = @_;

    my $base = $ENV{XDG_CACHE_HOME} || ( $ENV{HOME} ? "$ENV{HOME}/.cache" : undef );
    my $dir  = $self->{cache_dir} // ( $base ? "$base/trog-provisioner" : undef );
    return unless $dir;

    # A hash, because the endpoint has slashes and the id is a credential.
    # See "The token cache" for why the key holds both.
    my $key = Digest::SHA::sha256_hex("$self->{endpoint}\0$self->{credential_id}");

    return "$dir/openstack-token-$key.json";
}

=head1 REQUIREMENTS

To give this object to L<OpenStack::MetaAPI>, you need a version whose
C<BUILDARGS> keeps an C<auth> that you pass in.  Releases up to 0.003 always
make a new one from their arguments, and discard this object and its
credential.  This line tells you if your version keeps it:

    OpenStack::MetaAPI->new({auth => $auth})->auth == $auth

C<service> and C<services> do not need L<OpenStack::MetaAPI>.

=head1 SEE ALSO

L<Trog::OpenStack::Config>, which reads the credential.

L<Trog::OpenStack::UserAgent>, which makes sure that the connection checks the
certificate.

L<OpenStack::Client::Auth::v3>, whose C<service> and C<services> this inherits.

=cut

1;
