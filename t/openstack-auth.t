#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/openstack-auth.t - Trog::OpenStack::Auth: the application credential request,
and the token cache

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp       qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Cpanel::JSON::XS();
use POSIX qw{strftime};

use FindBin::libs;

## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use Trog::OpenStack::Auth();

# Stands in for OpenStack::Client::Response.  Only the two things the code under
# test asks of it: the decoded body, and the header the token arrives in.
{

    package Test::FakeResponse;

    sub new {
        my ( $class, %args ) = @_;
        return bless {%args}, $class;
    }
    sub decode_json { return $_[0]->{body} }
    sub header      { return $_[0]->{headers}{ $_[1] } }
}

# An ISO 8601 stamp $offset seconds from now, spelled the way Keystone spells
# it, so the expiry arithmetic is exercised against real input.
sub keystone_time {
    my ($offset) = @_;
    return strftime( '%Y-%m-%dT%H:%M:%S.000000Z', gmtime( time + $offset ) );
}

sub catalog {
    return [
        {
            type      => 'compute',
            name      => 'nova',
            endpoints => [ { interface => 'public', region => 'RegionOne', url => 'https://nova.example.net:8774/v2.1' } ],
        },
        {
            type      => 'identity',
            name      => 'keystone',
            endpoints => [ { interface => 'public', region => 'RegionOne', url => 'https://keystone.example.net:5000/v3' } ],
        },
    ];
}

# Mock the one call that reaches the network, and record what it was asked to
# send so the request body can be asserted on.
my @REQUESTS;
my $RESPONSE;

my $client = Test::MockModule->new('OpenStack::Client');
$client->redefine(
    request => sub {
        my ( $self, %args ) = @_;
        push @REQUESTS, { endpoint => $self->{endpoint}, %args };
        return $RESPONSE->();
    }
);

sub good_response {
    return sub {
        return Test::FakeResponse->new(
            headers => { 'X-Subject-Token' => 'a-token' },
            body    => {
                token => {
                    expires_at => keystone_time(3600),
                    catalog    => catalog(),
                    project    => { id => 'proj-uuid' },
                }
            },
        );
    };
}

sub fresh {
    @REQUESTS = ();
    $RESPONSE = good_response();
    return tempdir( CLEANUP => 1 );
}

my @CREDS = (
    application_credential_id     => 'cred-id',
    application_credential_secret => 'cred-secret',
);

subtest 'the request is an application credential request' => sub {
    my $dir = fresh();

    my $auth = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );

    is scalar @REQUESTS, 1, 'one round trip to Keystone';

    my $req = $REQUESTS[0];
    is $req->{method}, 'POST',         'POST';
    is $req->{path},   '/auth/tokens', 'to /auth/tokens';

    my $identity = $req->{body}{auth}{identity};
    is_deeply $identity->{methods}, ['application_credential'],
      'asking for the application_credential method and nothing else';
    is $identity->{application_credential}{id},     'cred-id',     'the credential id';
    is $identity->{application_credential}{secret}, 'cred-secret', 'and its secret';

    ok !exists $req->{body}{auth}{scope},
      'no scope: an application credential carries its own';

    is $auth->token,  'a-token', 'the token comes off the response header';
    is $auth->region, undef,     'no region was asked for';
    is_deeply [ $auth->services ], [ 'compute', 'identity' ], 'the catalogue is readable through the parent';
};

subtest 'the endpoint gets the identity version it needs' => sub {
    foreach my $case (
        [ 'https://keystone.example.net:5000/v3',  'https://keystone.example.net:5000/v3', 'already versioned' ],
        [ 'https://keystone.example.net:5000/v3/', 'https://keystone.example.net:5000/v3', 'a trailing slash' ],
        [ 'https://keystone.example.net:5000',     'https://keystone.example.net:5000/v3', 'bare host and port' ],
        [ 'https://keystone.example.net:5000/',    'https://keystone.example.net:5000/v3', 'bare, with a slash' ],
    ) {
        my ( $given, $want, $why ) = @$case;

        my $dir = fresh();
        Trog::OpenStack::Auth->new( $given, @CREDS, cache_dir => $dir );
        is $REQUESTS[0]{endpoint}, $want, $why;
    }
};

subtest 'a credential we do not have is not a request we send' => sub {
    my $dir = fresh();

    like exception { Trog::OpenStack::Auth->new( 'https://k.example.net/v3', application_credential_secret => 'x', cache_dir => $dir ) },
      qr/application_credential_id/, 'no id';
    like exception { Trog::OpenStack::Auth->new( 'https://k.example.net/v3', application_credential_id => 'x', cache_dir => $dir ) },
      qr/application_credential_secret/, 'no secret';
    like exception { Trog::OpenStack::Auth->new( '', @CREDS, cache_dir => $dir ) },
      qr/No Keystone endpoint/, 'no endpoint';

    is scalar @REQUESTS, 0, 'and none of them tried the network';
};

subtest 'a response that is missing the point is an error' => sub {
    my $dir = fresh();
    $RESPONSE = sub {
        return Test::FakeResponse->new( headers => {}, body => { token => { catalog => catalog() } } );
    };
    like exception { Trog::OpenStack::Auth->new( 'https://k.example.net/v3', @CREDS, cache_dir => $dir ) },
      qr/returned no token/, 'no token header';

    $dir      = fresh();
    $RESPONSE = sub {
        return Test::FakeResponse->new( headers => { 'X-Subject-Token' => 't' }, body => { token => { catalog => [] } } );
    };
    like exception { Trog::OpenStack::Auth->new( 'https://k.example.net/v3', @CREDS, cache_dir => $dir ) },
      qr/no service catalog/, 'an empty catalogue';

    # Whatever went wrong, the message has to name the endpoint -- a bare "401
    # Unauthorized" does not distinguish a revoked credential from the wrong
    # cloud, and those have different fixes.
    $dir      = fresh();
    $RESPONSE = sub { die "401 Unauthorized\n" };
    like exception { Trog::OpenStack::Auth->new( 'https://k.example.net/v3', @CREDS, cache_dir => $dir ) },
      qr{https://k\.example\.net/v3}, 'and says which endpoint refused us';
};

subtest 'the second command does not authenticate again' => sub {
    my $dir = fresh();

    my $first = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    is scalar @REQUESTS, 1, 'the first one did';

    my $second = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    is scalar @REQUESTS, 1, 'the second one did not';

    is $second->token, $first->token, 'and it has the same token';
    is_deeply [ $second->services ], [ $first->services ], 'and the same catalogue';
    is $second->{response}, undef, 'without an HTTP response behind it';

    # The whole reason token() is overridden: the parent reads it off a response
    # that a cached object has never had.
    ok defined $second->token, 'which is why token() does not go looking for one';
};

subtest 'the cached token is not left readable' => sub {
    my $dir = fresh();

    my $auth = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );

    my $path = $auth->cache_path;
    ok -e $path, 'the cache got written' or return;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)

    is sprintf( '%04o', ( stat $path )[2] & 0o7777 ), '0600', 'the file holds a bearer token, so 0600';
    is sprintf( '%04o', ( stat $dir )[2] & 0o7777 ),  '0700', 'and the directory it is in';

    ok index( $path, 'cred-id' ) < 0, 'and the credential id is not in the filename';
};

subtest 'a token near the end of its life is not used' => sub {
    my $dir = fresh();

    # Inside $EXPIRY_MARGIN. A provision takes minutes; a token with seconds
    # left on it would fail partway through rather than up front.
    $RESPONSE = sub {
        return Test::FakeResponse->new(
            headers => { 'X-Subject-Token' => 'nearly-done' },
            body    => { token             => { expires_at => keystone_time(60), catalog => catalog() } },
        );
    };

    Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    is scalar @REQUESTS, 1, 'authenticated';

    $RESPONSE = good_response();
    Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    is scalar @REQUESTS, 2, 'and authenticated again rather than trusting it';
};

subtest 'a cache that says it is for another endpoint is ignored' => sub {
    my $dir = fresh();

    my $auth = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    my $path = $auth->cache_path;

    # Rewrite it in place claiming a different cloud.  The endpoint is part of
    # the cache key, so this should not happen -- but if a stale file ever does
    # turn up under a name we compute, sending this cloud's token to it is the
    # one outcome that must not happen.
    my $cached = Cpanel::JSON::XS::decode_json( File::Slurper::read_binary($path) );
    $cached->{endpoint} = 'https://somewhere.else.example.net:5000/v3';
    File::Slurper::Temp::write_binary( $path, Cpanel::JSON::XS::encode_json($cached) );

    @REQUESTS = ();
    Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
    is scalar @REQUESTS, 1, 'authenticated from scratch';
};

subtest 'a corrupt cache costs a round trip and nothing else' => sub {
    foreach my $rubbish ( '', 'not json at all', '{"token":"t"}', '[]' ) {
        my $dir = fresh();

        my $auth = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );
        File::Slurper::Temp::write_binary( $auth->cache_path, $rubbish );

        @REQUESTS = ();
        my $again = Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir );

        is scalar @REQUESTS, 1,         "re-authenticated rather than died on: '$rubbish'";
        is $again->token,    'a-token', 'and came back usable';
    }
};

subtest 'no_cache means no cache' => sub {
    my $dir = fresh();

    Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir, no_cache => 1 );
    Trog::OpenStack::Auth->new( 'https://keystone.example.net:5000/v3', @CREDS, cache_dir => $dir, no_cache => 1 );

    is scalar @REQUESTS, 2, 'every construction authenticates';
};

subtest 'from_cloud reads clouds.yaml, and refuses what it cannot do' => sub {
    my $dir = fresh();

    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME}     = $home;
    local $ENV{OS_CLOUD} = undef;
    delete local $ENV{OS_CLIENT_CONFIG_FILE};
    delete local $ENV{OS_AUTH_URL};
    delete local $ENV{OS_APPLICATION_CREDENTIAL_ID};
    delete local $ENV{OS_APPLICATION_CREDENTIAL_SECRET};

    File::Slurper::Temp::write_binary(
        "$home/clouds.yaml", <<'YAML'
clouds:
  openstack:
    auth:
      auth_url: https://keystone.example.net:5000/v3
      application_credential_id: "from-file"
      application_credential_secret: "secret-from-file"
    region_name: "RegionOne"
    interface: "public"
    auth_type: "v3applicationcredential"
YAML
    );

    my $auth = Trog::OpenStack::Auth->from_cloud( undef, cache_dir => $dir );
    is $REQUESTS[0]{body}{auth}{identity}{application_credential}{id}, 'from-file',
      'the credential out of the file is the one sent';
    is $auth->region,    'RegionOne', 'the region comes along for later service() calls';
    is $auth->interface, 'public',    'and the interface';

    # A password cloud is a perfectly good clouds.yaml that this cannot use, so
    # say so rather than sending a request that cannot succeed.
    File::Slurper::Temp::write_binary(
        "$home/clouds.yaml", <<'YAML'
clouds:
  openstack:
    auth:
      auth_url: https://keystone.example.net:5000/v3
      username: someone
      password: hunter2
    auth_type: "password"
YAML
    );

    @REQUESTS = ();
    my $err = exception { Trog::OpenStack::Auth->from_cloud( undef, cache_dir => $dir ) };
    like $err, qr/v3applicationcredential/, 'it says what it does speak';
    like $err, qr/password/,                'and what it was given';
    is scalar @REQUESTS, 0, 'and did not try anyway';
};

done_testing();
