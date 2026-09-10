package Trog::OpenStack::Auth;

#ABSTRACT: Keystone v3 application credentials, and the token that comes back.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent 'OpenStack::Client::Auth::v3';

use Cpanel::JSON::XS();
use Digest::SHA();
use File::Path();
use File::Slurper();
use File::Slurper::Temp();
use OpenStack::Client();
use Time::Piece();

use Trog::OpenStack::Config();

# Loaded for its side effect, and named only as a string below: OpenStack::Client
# takes the user agent as a class name and calls new() on it, so the class has to
# already be there when it does.
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

L<OpenStack::Client::Auth::v3> authenticates one way: it puts
C<methods =E<gt> ['password']> in the request and dies without a password.  An
application credential has neither a username nor a password -- it is an id and
a secret, issued by Keystone, scoped to a project when it was made -- so there
is nothing to give it.

This is that request instead.  Everything after the token is the parent's:
C<service> resolves a service type against the catalogue and hands back an
L<OpenStack::Client> pointed at it, and C<services> lists what the catalogue
had.  Only C<token> is overridden, because a token restored from cache never
had an HTTP response to read it out of.

=head2 On the token cache

Authenticating is a round trip to Keystone, and every command that touches the
cloud would otherwise start with one.

The cached token is trusted until Keystone's own C<expires_at> says not to,
less C<$EXPIRY_MARGIN>.  That is the difference between this and asking the
cloud whether the token is still good: the answer is already in the token, so
there is no probe request to make, and no window where a token that expires
mid-run looked fine when we checked.

The cache is keyed on the endpoint and the credential id together, so a second
cloud, or the same cloud with a rotated credential, does not read the first
one's token.  The file holds a bearer credential and is written 0600 in a 0700
directory.

=head1 CLASS METHODS

=cut

# What we refuse to rely on the tail end of.  A provision takes minutes, and a
# token with a minute left on it fails partway through instead of at the start,
# which is a much worse way to find out.
our $EXPIRY_MARGIN = 300;

=head2 from_cloud($name)

Authenticate against a cloud out of F<clouds.yaml>.  C<$name> is passed to
L<Trog::OpenStack::Config/load>, so it defaults to C<$OS_CLOUD> or to the only
cloud in the file.

Dies naming the cloud when it is not configured for an application credential,
rather than sending a request that cannot work.

=cut

sub from_cloud {
    my ( $class, $name, %args ) = @_;

    my $cloud = Trog::OpenStack::Config->load($name);

    die "Cloud '$cloud->{name}' in $cloud->{source} authenticates with '$cloud->{auth_type}'.\n" . "This only speaks v3applicationcredential.\n"
      unless $cloud->{auth_type} eq 'v3applicationcredential';

    return $class->new(
        $cloud->{auth_url},
        application_credential_id     => $cloud->{application_credential_id},
        application_credential_secret => $cloud->{application_credential_secret},
        region                        => $cloud->{region_name},
        interface                     => $cloud->{interface},
        %args,
    );
}

=head2 new($endpoint, %args)

Required: C<application_credential_id> and C<application_credential_secret>.

Optional: C<region> and C<interface>, remembered so callers do not have to
repeat them at every C<service> call; C<cache_dir>, and C<no_cache> to skip the
cache entirely; and the C<package_ua>, C<package_request> and C<package_response>
that L<OpenStack::Client> takes.

C<package_ua> defaults to L<Trog::OpenStack::UserAgent> rather than
L<LWP::UserAgent>, because L<OpenStack::Client> would otherwise turn off TLS
hostname verification for a connection we are about to send a token over.

=cut

sub new {
    my ( $class, $endpoint, %args ) = @_;

    die "No Keystone endpoint provided\n" unless defined $endpoint && length $endpoint;

    my $id     = $args{application_credential_id};
    my $secret = $args{application_credential_secret};

    die "No application credential id provided in \"application_credential_id\"\n"
      unless defined $id && length $id;
    die "No application credential secret provided in \"application_credential_secret\"\n"
      unless defined $secret && length $secret;

    my $self = bless {
        package_ua       => $args{package_ua} // 'Trog::OpenStack::UserAgent',
        package_request  => $args{package_request},
        package_response => $args{package_response},
        clients          => {},
        services         => [],
        endpoint         => _identity_endpoint($endpoint),
        region           => $args{region},
        interface        => $args{interface},
        credential_id    => $id,
        cache_dir        => $args{cache_dir},
        no_cache         => $args{no_cache},
    }, $class;

    return $self if $self->_restore;

    $self->_authenticate($secret);
    $self->_store;

    return $self;
}

# clouds.yaml files disagree about whether auth_url carries the identity
# version: the one Horizon issues ends in /v3, and openstacksdk documents
# auth_url both ways, so either can turn up.  Both have to end up at
# /v3/auth/tokens, and OpenStack::Client builds its paths by joining onto the
# endpoint.
sub _identity_endpoint {
    my ($endpoint) = @_;

    $endpoint =~ s{/+$}{};
    return $endpoint if $endpoint =~ m{/v3$};
    return "$endpoint/v3";
}

=head1 OBJECT METHODS

=head2 token

The Keystone token, as C<X-Auth-Token> wants it.

Overrides the parent, which reads it off the HTTP response headers.  A token
that came out of the cache has no response behind it.

=head2 expires_at

When Keystone says the token stops working, in its own ISO 8601 spelling.

=head2 region, interface

What was passed to the constructor, for callers assembling C<service> options.

=cut

sub token      { return $_[0]->{token} }
sub expires_at { return $_[0]->{expires_at} }
sub region     { return $_[0]->{region} }
sub interface  { return $_[0]->{interface} }

# The one request this module exists to make.
sub _authenticate {
    my ( $self, $secret ) = @_;

    my ( $response, $body );
    my $ok = eval {
        my $client = OpenStack::Client->new(
            $self->{endpoint},
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
                            id     => $self->{credential_id},
                            secret => $secret,
                        },
                    },
                },
            },
        );

        $body = $response->decode_json;
        1;
    };

    # The whole exchange is in there, not just the decode, because any part of
    # it can be what fails and all of them need the same thing said about it.
    # decode_json is the usual one -- it dies on a 4xx with the response body as
    # the message -- and "401 Unauthorized" on its own does not distinguish a
    # revoked credential from the wrong cloud, which have different fixes.
    die "Authenticating against $self->{endpoint} failed: $@" unless $ok;

    my $token = $response->header('X-Subject-Token');
    die "Authenticating against $self->{endpoint} returned no token\n"
      unless defined $token && length $token;

    my $catalog = $body->{token}{catalog};
    die "Authenticating against $self->{endpoint} returned no service catalog\n"
      unless ref $catalog eq 'ARRAY' && @$catalog;

    $self->{response}   = $response;
    $self->{body}       = $body;
    $self->{token}      = $token;
    $self->{expires_at} = $body->{token}{expires_at};
    $self->{services}   = $catalog;

    return 1;
}

=head1 THE CACHE

=head2 cache_path

The file this object's token is cached in, or nothing when there is nowhere to
put it.

=cut

sub cache_path {
    my ($self) = @_;

    my $dir = $self->{cache_dir} // _default_cache_dir();
    return unless defined $dir && length $dir;

    # Neither the endpoint nor the credential id belongs in a filename -- one
    # has slashes in it and the other is a credential -- and both have to be in
    # the key, so that a rotated credential or a moved endpoint does not read
    # the token issued to the old one.
    my $key = Digest::SHA::sha256_hex("$self->{endpoint}\0$self->{credential_id}");

    return "$dir/openstack-token-$key.json";
}

sub _default_cache_dir {
    my $base = $ENV{XDG_CACHE_HOME};
    $base = "$ENV{HOME}/.cache" if !length( $base // '' ) && length( $ENV{HOME} // '' );

    return unless length( $base // '' );
    return "$base/trog-provisioner";
}

# Put a usable cached token on $self, and say whether there was one.
sub _restore {
    my ($self) = @_;

    return 0 if $self->{no_cache};

    my $path = $self->cache_path;
    return 0 unless defined $path;

    # A cache that is missing, unreadable, truncated or from another version of
    # this code is a cache miss and nothing worse.  It only ever costs us the
    # round trip we were trying to save.
    my $cached = eval { Cpanel::JSON::XS::decode_json( File::Slurper::read_binary($path) ) };
    return 0 unless ref $cached eq 'HASH';

    return 0 unless _looks_current( $cached, $self->{endpoint} );

    $self->{token}      = $cached->{token};
    $self->{expires_at} = $cached->{expires_at};
    $self->{services}   = $cached->{catalog};

    return 1;
}

# Is this cache entry for the cloud we are talking to, and good for long enough
# to be worth using?
sub _looks_current {
    my ( $cached, $endpoint ) = @_;

    return 0 unless length( $cached->{token} // '' );
    return 0 unless ref $cached->{catalog} eq 'ARRAY' && @{ $cached->{catalog} };

    # The endpoint is in the cache key already, so this is belt and braces --
    # but a stale file under a colliding name would otherwise send a token to
    # the wrong cloud, and that is worth two lines to rule out.
    return 0 unless ( $cached->{endpoint} // '' ) eq $endpoint;

    return _epoch_of( $cached->{expires_at} ) - $EXPIRY_MARGIN > time();
}

# Keystone's expires_at, as an epoch.  0 when it cannot be read, which reads as
# "expired" everywhere this is used.
sub _epoch_of {
    my ($iso) = @_;

    return 0 unless defined $iso;

    my ($stamp) = $iso =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/;
    return 0 unless defined $stamp;

    # Keystone reports UTC, which is what strptime assumes.
    my $parsed = eval { Time::Piece->strptime( $stamp, '%Y-%m-%dT%H:%M:%S' ) };
    return $parsed ? $parsed->epoch : 0;
}

# Write the token out for the next command to find.  Failing to cache is not an
# error: it makes the next run slower and nothing else, so it must not take down
# a provision that has otherwise authenticated fine.
sub _store {
    my ($self) = @_;

    return 0 if $self->{no_cache};

    my $path = $self->cache_path;
    return 0 unless defined $path;

    my $encoded = Cpanel::JSON::XS::encode_json(
        {
            token      => $self->{token},
            expires_at => $self->{expires_at},
            catalog    => $self->{services},
            endpoint   => $self->{endpoint},
        }
    );

    my $ok = eval {
        my ($dir) = $path =~ m{^(.*)/[^/]+$};
        File::Path::make_path( $dir, { mode => 0o700 } );

        # Atomically, because two provisions running at once would otherwise
        # race to leave a half-written file that the next run has to treat as
        # corrupt.
        File::Slurper::Temp::write_binary( $path, $encoded );
        chmod 0600, $path;
        1;
    };

    return $ok ? 1 : 0;
}

=head1 REQUIREMENTS

Handing this to L<OpenStack::MetaAPI> needs a version of it whose C<BUILDARGS>
honours an C<auth> that was passed in.  Releases up to 0.003 rebuild it from
their arguments unconditionally and throw away the object, which loses the
credential this module exists to carry.  The check is one line:

    OpenStack::MetaAPI->new({auth => $auth})->auth == $auth

Nothing here needs it; C<service> and C<services> work on their own.

=head1 SEE ALSO

L<Trog::OpenStack::Config>, which says where the credential came from.

L<Trog::OpenStack::UserAgent>, which is why the connection is verified.

L<OpenStack::Client::Auth::v3>, whose C<service> and C<services> this inherits.

=cut

1;
