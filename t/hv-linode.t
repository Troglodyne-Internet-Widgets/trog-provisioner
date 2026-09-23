#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hv-linode.t - Trog::HV::Linode: what a guest costs, how one is built,
snapshotted and torn down, and what Linode is asked for each

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Capture::Tiny();
use Config::Simple();
use Cpanel::JSON::XS();
use MIME::Base64();
use Mojolicious();

use FindBin::libs;

use Linode::API();
use Trog::HV();
use Trog::HV::Linode();
use Trog::Secrets();        ## no critic (ProhibitUnusedImports) -- mocked below
use Trog::Credentials();    ## no critic (ProhibitUnusedImports) -- mocked below

local $Trog::HV::Linode::POLL           = 0;
local $Trog::HV::Linode::BUILD_TIMEOUT  = 2;
local $Trog::HV::Linode::IMAGE_TIMEOUT  = 2;
local $Trog::HV::Linode::BUSY_TIMEOUT   = 1;
local $Trog::HV::Linode::DELETE_TIMEOUT = 1;

# A stand-in for Linode that keeps state, so a wait for a state change has one
# to wait for, and records every request, so the assertions are about what was
# asked.  The client in front of it is the real one: every body is validated
# against Linode's specification before it gets here.
my ( %STATE, @ASKED );

sub reset_linode {
    %STATE = (
        types => [
            {
                id            => 'g6-standard-2',
                memory        => 4096,
                vcpus         => 2,
                disk          => 81920,
                price         => { monthly => 24, hourly => 0.036 },
                region_prices => [ { id => 'br-gru', monthly => 28.8, hourly => 0.043 } ],
                addons        => { backups => { price => { monthly => 5, hourly => 0.0075 }, region_prices => [] } },
            },
            {
                id            => 'g6-nanode-1',
                memory        => 1024,
                vcpus         => 1,
                disk          => 25600,
                price         => { monthly => 5, hourly => 0.0075 },
                region_prices => [],
                addons        => { backups => { price => { monthly => 2, hourly => 0.003 }, region_prices => [] } },
            },
            {
                id            => 'g1-gpu-rtx6000-1',
                memory        => 32768,
                vcpus         => 8,
                disk          => 655360,
                price         => { monthly => undef, hourly => 1.5 },
                region_prices => [],
                addons        => { backups => { price => { monthly => undef, hourly => 0.1 }, region_prices => [] } },
            },
        ],
        regions => [
            { id => 'us-east', capabilities => [qw{Linodes Metadata}] },
            { id => 'us-west', capabilities => [qw{Linodes}] },
            { id => 'br-gru',  capabilities => [qw{Linodes Metadata}] },
        ],
        images => [
            { id => 'linode/ubuntu24.04', capabilities => ['cloud-init'], description => undef, created => '2024-04-01T00:00:00' },
            { id => 'linode/arch',        capabilities => [],             description => undef, created => '2024-04-01T00:00:00' },
        ],
        linodes => [],
        disks   => {},
        volumes => {},
        next    => 100,
    );
    @ASKED = ();
    return;
}

# What image_for_distro asks of a distro recipe, and nothing else.
{

    package Test::Distro;
    sub new             ( $class, $distribution, $version ) { return bless { distribution => $distribution, version => $version }, $class }
    sub distribution    ($self)                             { return $self->{distribution} }
    sub release_version ($self)                             { return $self->{version} }
}

sub linode_of ($label) {
    return ( grep { $_->{label} eq $label } @{ $STATE{linodes} } )[0];
}

sub add_linode {
    my (%linode) = @_;
    my $id = $STATE{next}++;
    push @{ $STATE{linodes} }, { id => $id, status => 'running', region => 'us-east', type => 'g6-standard-2', ipv4 => ['203.0.113.10'], backups => { enabled => Cpanel::JSON::XS::false() }, %linode };
    $STATE{disks}{$id} = [ { id => $id * 10, filesystem => 'ext4', size => 81408 }, { id => $id * 10 + 1, filesystem => 'swap', size => 512 } ];
    return $id;
}

# The states a Linode passes through on the way to another, which the next look
# finds it out of.
my %TRANSIENT = map { $_ => 1 } qw{provisioning rebuilding booting shutting_down};

my $FAKE = Mojolicious->new;
$FAKE->log->level('fatal');
{
    my $r = $FAKE->routes;

    my $page  = sub ( $c, @data ) { $c->render( json => { data => \@data, page => 1, pages => 1, results => scalar @data } ) };
    my $asked = sub ($c) {
        my $req = $c->req;
        push @ASKED, [ $req->method, $req->url->path->to_string, $req->json ];
        return;
    };
    my $find = sub ($c) {
        return ( grep { $_->{id} == $c->param('id') } @{ $STATE{linodes} } )[0];
    };

    $r->get('/v4/profile')->to( cb => sub ($c) { $asked->($c); $c->render( json => { username => 'test' } ) } );
    $r->get('/v4/linode/types')->to( cb => sub ($c) { $asked->($c); $page->( $c, @{ $STATE{types} } ) } );
    $r->get('/v4/regions')->to(
        cb => sub ($c) {
            $asked->($c);
            return $c->render( status => 401, json => { errors => [ { reason => 'Invalid Token' } ] } ) if $STATE{refuse_token};
            $page->( $c, @{ $STATE{regions} } );
        }
    );
    $r->get('/v4/images')->to(
        cb => sub ($c) {
            $asked->($c);
            $page->(
                $c,
                map {
                    { %$_ }
                } @{ $STATE{images} }
            );
        }
    );

    $r->get('/v4/images/*imageId')->to(
        cb => sub ($c) {
            $asked->($c);
            my ($image) = grep { $_->{id} eq $c->param('imageId') } @{ $STATE{images} };
            return $c->render( status => 404, json => { errors => [ { reason => 'Not found' } ] } ) unless $image;

            my $shown = {%$image};
            $image->{status} = 'available';    # the next look finds it captured
            $c->render( json => $shown );
        }
    );

    $r->post('/v4/images')->to(
        cb => sub ($c) {
            $asked->($c);
            return $c->render( status => 400, json => { errors => [ { reason => 'Image too large' } ] } ) if $STATE{refuse_image};
            my $image = { %{ $c->req->json }, id => 'private/' . $STATE{next}++, status => 'creating', capabilities => ['cloud-init'], created => sprintf( '2026-09-21T00:00:%02d', scalar @{ $STATE{images} } ) };
            push @{ $STATE{images} }, $image;
            $c->render( json => $image );
        }
    );

    $r->get('/v4/linode/instances')->to(
        cb => sub ($c) {
            $asked->($c);
            my $filter = Cpanel::JSON::XS::decode_json( $c->req->headers->header('X-Filter') // '{}' );
            my @shown  = grep { !defined $filter->{label} || $_->{label} eq $filter->{label} } @{ $STATE{linodes} };
            @{ $STATE{linodes} } = grep { $_->{status} ne 'deleting' || $_->{stuck} } @{ $STATE{linodes} };
            $page->( $c, @shown );
        }
    );

    $r->post('/v4/linode/instances')->to(
        cb => sub ($c) {
            $asked->($c);
            my $body = $c->req->json;
            add_linode( label => $body->{label}, region => $body->{region}, type => $body->{type}, status => 'provisioning', ipv4 => [ '192.168.140.7', '203.0.113.20' ] );
            $c->render( json => linode_of( $body->{label} ) );
        }
    );

    $r->get('/v4/linode/instances/:id')->to(
        cb => sub ($c) {
            $asked->($c);
            my $linode = $find->($c);
            my $shown  = {%$linode};
            if ( my $then = delete $linode->{then} ) {
                $linode->{status} = $then;
            }
            elsif ( $TRANSIENT{ $linode->{status} } ) {
                $linode->{status} = $linode->{becomes} // 'running';
            }
            delete $shown->{then};
            $c->render( json => $shown );
        }
    );

    $r->post('/v4/linode/instances/:id/rebuild')->to(
        cb => sub ($c) {
            $asked->($c);
            my $linode = $find->($c);
            return $c->render( status => 400, json => { errors => [ { reason => 'Linode busy.' } ] } ) if $STATE{busy} && $STATE{busy}--;

            # Linode goes on saying what it was saying for one more look.
            $linode->{then}    = 'rebuilding';
            $linode->{becomes} = 'running';
            $linode->{type}    = $c->req->json->{type} if $c->req->json->{type};
            $c->render( json => $linode );
        }
    );

    $r->post('/v4/linode/instances/:id/shutdown')->to( cb => sub ($c) { $asked->($c); my $l = $find->($c); @$l{qw{status becomes}} = qw{shutting_down offline}; $c->render( json => {} ) } );
    $r->post('/v4/linode/instances/:id/boot')->to( cb => sub ($c) { $asked->($c); my $l = $find->($c); @$l{qw{status becomes}} = qw{booting running}; $c->render( json => {} ) } );

    $r->delete('/v4/linode/instances/:id')->to(
        cb => sub ($c) {
            $asked->($c);
            $find->($c)->{status} = 'deleting';    # still listed, the next look once
            $c->render( json => {} );
        }
    );

    $r->get('/v4/linode/instances/:id/disks')->to( cb => sub ($c) { $asked->($c); $page->( $c, @{ $STATE{disks}{ $c->param('id') } // [] } ) } );
    $r->get('/v4/linode/instances/:id/volumes')->to( cb => sub ($c) { $asked->($c); $page->( $c, @{ $STATE{volumes}{ $c->param('id') } // [] } ) } );
}

my $mock = Test::MockModule->new('Trog::HV::Linode');
$mock->redefine( api => sub ($self) { return $self->{_api} //= Linode::API->new( token => 'test-token', app => $FAKE ) } );

sub linode_hv (%opts) {
    reset_linode() unless %STATE;
    return Trog::HV::Linode->build( linode_token => 'secret:linode/api/password', region => 'us-east', %opts );
}

# What a call warned, which Test::NoWarnings would otherwise take as a failure,
# and what it returned.
sub warned ($code) {
    my $warned = q{};
    local $SIG{__WARN__} = sub { $warned .= join( q{}, @_ ) };
    my @result = $code->();
    return ( $warned, @result );
}

sub asked_to ( $method, $path ) {
    return grep { $_->[0] eq $method && $_->[1] eq $path } @ASKED;
}

sub config_for ($domain) {
    my $config = Config::Simple->new( syntax => 'simple' );
    $config->param( domain      => $domain );
    $config->param( image       => 'linode/ubuntu24.04' );
    $config->param( linode_type => 'g6-standard-2' );
    return $config;
}

subtest 'build' => sub {
    like( exception { Trog::HV::Linode->build( region       => 'us-east' ) }, qr/needs[ ]linode_token/,                    'a block has to say which account' );
    like( exception { Trog::HV::Linode->build( linode_token => 'abc123' ) },  qr/has[ ]to[ ]be[ ]a[ ]secret:[ ]reference/, 'and never with the token written out' );
    isa_ok( linode_hv(), 'Trog::HV::Cloud', 'a Linode hypervisor' );
    is( linode_hv()->describe, 'Linode in us-east', 'described by where it builds' );
};

subtest 'backend_for' => sub {
    is( Trog::HV->backend_for( linode_token => 'secret:a/b/password' ), 'Trog::HV::Linode',    'a token chooses Linode' );
    is( Trog::HV->backend_for( cloud        => 'openstack' ),           'Trog::HV::OpenStack', 'a cloud still chooses OpenStack' );
    is( Trog::HV->backend_for(), 'Trog::HV::Libvirt', 'and nothing still chooses libvirt' );
    like(
        exception { Trog::HV->backend_for( cloud => 'openstack', linode_token => 'secret:a/b/password' ) },
        qr/this[ ]has[ ]cloud[ ]and[ ]linode_token/,
        'and two kinds at once are refused, in the keys of the file',
    );
};

subtest '_token' => sub {
    my %asked;
    my $secrets = Test::MockModule->new('Trog::Secrets');
    $secrets->redefine( lookup => sub ( $class, $file, $password, %needed ) { %asked = ( file => $file, password => $password, %needed ); return ( linode_token => 'the-token' ) } );
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( prompt => sub ( $class, $message, $name, @ ) { return "passphrase for $name" } );

    is( linode_hv()->_token,  'the-token',                  'the token comes out of the secret store' );
    is( $asked{linode_token}, 'secret:linode/api/password', 'by the reference the block names' );
    is( $asked{password},     'passphrase for keepass',     'unlocked with the passphrase this run has for it' );
};

subtest 'monthly_cost and monthly_spend' => sub {
    reset_linode();

    # The type is the guest's, not the block's: what a guest costs is what it
    # asked to be.
    is( linode_hv()->monthly_cost( linode_type => 'g6-standard-2' ), 24, 'the price of the type the guest names' );
    is( linode_hv()->monthly_cost( linode_type => 'g6-nanode-1' ),   5,  'whichever type that is' );
    is( linode_hv( region => 'br-gru' )->monthly_cost( linode_type => 'g6-standard-2' ), 28.8, 'in the region, where the region prices it differently' );

    like( exception { linode_hv()->monthly_cost },                                                    qr/names[ ]none/,           'a guest that names no type has no price here' );
    like( exception { linode_hv( region => undef )->monthly_cost( linode_type => 'g6-standard-2' ) }, qr/Say[ ]which[ ]region/,   'and no price without a region' );
    like( exception { linode_hv()->monthly_cost( linode_type => 'g1-bogus' ) },                       qr/no[ ]type[ ]'g1-bogus'/, 'nor for a type Linode does not sell' );

    add_linode( label => 'a.test.test' );
    add_linode( label => 'b.test.test', type   => 'g6-nanode-1', backups => { enabled => Cpanel::JSON::XS::true() } );
    add_linode( label => 'c.test.test', region => 'br-gru' );
    is( linode_hv()->monthly_spend, 24 + 5 + 2 + 28.8, 'the account is every Linode on it, with backups where they are on, at its region\'s price' );
};

subtest 'capacity and shortfalls' => sub {
    reset_linode();
    add_linode( label => 'a.test.test' );
    my $hv   = linode_hv( monthly_budget => 60 );
    my %big  = ( memory_mb => 4096, cpus => 2, disk_bytes => 40 * 1024**3, linode_type => 'g6-standard-2' );
    my %tiny = ( memory_mb => 1024, cpus => 1, disk_bytes => 1, linode_type => 'g6-nanode-1' );

    is_deeply(
        $hv->capacity(%big),
        {
            memory_mb => 4096, memory_committed => 0, memory_free    => 4096,
            cpus      => 2,    cpus_allocatable => 2, cpus_committed => 0, cpus_free => 2,
            disk_free => 81920 * 1024 * 1024,
            guests    => 1,
        },
        'one guest of the type it named, nothing committed against it, and the Linodes on the account',
    );
    is( $hv->capacity(%tiny)->{memory_mb}, 1024, 'and another guest gets the type it named' );

    is_deeply( [ $hv->shortfalls(%big) ], [], 'a guest the type it named holds, inside the budget, fits' );

    my @short = $hv->shortfalls( %big, memory_mb => 8192 );
    like( $short[0], qr/needs[ ]8192MB[ ]of[ ]memory,[ ]4096MB[ ]free/, 'a guest bigger than the type it named does not' );

    # Which is how a guest is kept off Linode: it says nothing about Linode.
    @short = $hv->shortfalls( memory_mb => 1024, cpus => 1, disk_bytes => 1 );
    is_deeply( \@short, ['names no linode_type, so it is not built on Linode'], 'and a guest that names no type is not built here at all' );

    $hv    = linode_hv( monthly_budget => 40 );
    @short = $hv->shortfalls(%big);
    is( scalar @short, 1, 'nor does one that would go over the budget' );
    like( $short[0], qr/g6-standard-2[ ]costs[ ]24[.]00[ ]a[ ]month/, 'saying what the guest costs' );
    like( $short[0], qr/already[ ]costs[ ]24[.]00/,                   'and what the account does' );
    like( $short[0], qr/monthly_budget[ ]of[ ]40[.]00/,               'against its budget' );

    is( scalar linode_hv( monthly_budget => 48 )->shortfalls(%big),                          0, 'and exactly the budget is inside it' );
    is( linode_hv()->reserve_memory + linode_hv()->reserve_cpus + linode_hv()->reserve_disk, 0, 'no reserve, because there is no host to keep one for' );
};

subtest 'cheapest_for' => sub {
    reset_linode();
    my %needs = ( memory_mb => 2048, cpus => 1, disk_bytes => 30 * 1024**3 );

    # g6-nanode-1 is cheaper and too small; the standard holds it.
    is_deeply( linode_hv()->cheapest_for(%needs),                                         { key => 'linode_type', value => 'g6-standard-2', monthly_cost => 24 }, 'the cheapest type that holds the guest, and what it costs' );
    is_deeply( linode_hv()->cheapest_for( memory_mb => 512, cpus => 1, disk_bytes => 1 ), { key => 'linode_type', value => 'g6-nanode-1',   monthly_cost => 5 },  'a smaller guest is offered a smaller one' );
    is( linode_hv()->cheapest_for( memory_mb => 999_999, cpus => 1, disk_bytes => 1 ), undef, 'and a guest Linode sells nothing big enough for is offered nothing' );

    # Linode prices its GPU and accelerated types by the hour alone.  Read as
    # free, one of those is the cheapest thing it sells, and it is not.
    is_deeply(
        linode_hv()->cheapest_for( memory_mb => 8192, cpus => 4, disk_bytes => 1 ),
        { key => 'linode_type', value => 'g1-gpu-rtx6000-1', monthly_cost => 1.5 * 730, hourly => 1.5 },
        'a type Linode prices by the hour alone is offered at a month of that rate, and says it is hourly'
    );
    is( linode_hv()->monthly_cost( linode_type => 'g1-gpu-rtx6000-1' ), 1.5 * 730, 'which is what it costs for a month, since Linode publishes no price to cap it' );
    ok( !exists linode_hv()->cheapest_for( memory_mb => 512, cpus => 1, disk_bytes => 1 )->{hourly}, 'while a type it does price by the month says nothing about hours' );

    # An offer that cannot be accepted is noise, so the budget rules it out.
    add_linode( label => 'a.test.test' );
    is( linode_hv( monthly_budget => 30 )->cheapest_for(%needs), undef, 'a type the budget leaves no room for is not offered' );
    is_deeply( linode_hv( monthly_budget => 30 )->cheapest_for( memory_mb => 512, cpus => 1, disk_bytes => 1 ), { key => 'linode_type', value => 'g6-nanode-1', monthly_cost => 5 }, 'while one it does leave room for still is' );
};

subtest 'guests' => sub {
    reset_linode();
    add_linode( label => 'vm.test.test', ipv4 => [ '192.168.139.4', '203.0.113.30' ] );
    add_linode( label => 'vm.test.test.other' );
    my $hv = linode_hv();

    is( $hv->linode('vm.test.test')->{label}, 'vm.test.test', 'a Linode is found by its label' );
    ok( $hv->domain_exists('vm.test.test'),    'and exists' );
    ok( !$hv->domain_exists('nope.test.test'), 'and one that is not there, does not' );
    is_deeply( [ sort $hv->guest_names ], [qw{vm.test.test vm.test.test.other}], 'every label on the account is a name in use' );

    is( $hv->guest_ssh_ip( config_for('vm.test.test') ), '203.0.113.30', 'reached at the public address, not the private one' );
    is( $hv->guest_ssh_ip('vm.test.test'),               '203.0.113.30', 'by name as well as by configuration' );

    $STATE{linodes}[0]{ipv4} = ['192.168.139.4'];
    like( exception { $hv->guest_ssh_ip('vm.test.test') },   qr/no[ ]public[ ]IPv4/,                       'one with only a private address says so' );
    like( exception { $hv->guest_ssh_ip('nope.test.test') }, qr/no[ ]guest[ ]called[ ]'nope\.test\.test'/, 'and so does one that is not there' );
};

subtest 'create_guest' => sub {
    reset_linode();
    my $hv = linode_hv( firewall_id => 42, private_ip => 1 );

    my $linode = $hv->create_guest( image => 'linode/ubuntu24.04', size => 'g6-standard-2', name => 'new.test.test', user_data => "#cloud-config\n" );
    is( $linode->{status}, 'running', 'it waits until Linode says the guest is running' );

    my ($created) = asked_to( POST => '/v4/linode/instances' );
    my $body = $created->[2];
    is( $body->{label},       'new.test.test',      'labeled with the domain' );
    is( $body->{region},      'us-east',            'in the region of the block' );
    is( $body->{type},        'g6-standard-2',      'of the type the guest named' );
    is( $body->{image},       'linode/ubuntu24.04', 'from its image' );
    is( $body->{firewall_id}, 42,                   'behind its firewall' );
    ok( $body->{private_ip}, 'with a private address, as asked' );
    is_deeply( $body->{tags}, ['trog-provisioner'], 'tagged as ours' );
    is( MIME::Base64::decode_base64( $body->{metadata}{user_data} ), "#cloud-config\n", 'with the seed for the metadata service' );
    like( $body->{root_pass}, qr/\A\S{48}\z/, 'and a long random root password, which Linode requires' );

    reset_linode();
    linode_hv()->create_guest( image => 'linode/ubuntu24.04', size => 'g6-standard-2', name => 'again.test.test' );
    isnt( ( asked_to( POST => '/v4/linode/instances' ) )[0][2]{root_pass}, $body->{root_pass}, 'a different one each time' );

    like( exception { linode_hv()->create_guest( name => 'x.test.test' ) },                                                                                     qr/needs[ ]an[ ]image/, 'no image is said, not sent' );
    like( exception { linode_hv()->create_guest( image => 'linode/ubuntu24.04', size => 'g6-standard-2', name => 'big.test.test', user_data => 'x' x 65536 ) }, qr/65536[ ]bytes/,      'nor a payload over what the metadata service takes' );
    like( exception { linode_hv()->create_guest( image => 'linode/ubuntu24.04', size => 'g6-standard-2', name => 'x' x 65 ) },                                  qr/64[ ]characters/,    'nor a label Linode would refuse' );

    reset_linode();
    like( exception { linode_hv()->create_guest( image => 'linode/ubuntu24.04', size => 'g6-standard-2', name => 'ab' ) }, qr/Linode[ ]refused[ ]post-linode-instance:[ ]400[ ]\/body/, 'a body the specification refuses is refused before it is sent' );
    is( scalar asked_to( POST => '/v4/linode/instances' ), 0, 'and nothing was sent' ) or diag explain \@ASKED;
};

subtest 'rebuild_guest' => sub {
    reset_linode();
    add_linode( label => 'vm.test.test', type => 'g6-nanode-1' );
    my $hv = linode_hv();

    my $linode = $hv->rebuild_guest( 'vm.test.test', image => 'linode/ubuntu24.04', size => 'g6-standard-2', user_data => "#cloud-config\n" );
    is( $linode->{status},                   'running', 'it waits until the rebuilt guest is running' );
    is( linode_of('vm.test.test')->{status}, 'running', 'running after the rebuild, not the running Linode reported before it began' );

    my ($rebuilt) = map { $_->[2] } grep { $_->[1] =~ m{/rebuild\z} } @ASKED;
    is( $rebuilt->{image},                                              'linode/ubuntu24.04', 'onto the image it was given' );
    is( MIME::Base64::decode_base64( $rebuilt->{metadata}{user_data} ), "#cloud-config\n",    'with the new seed' );
    is( $rebuilt->{type},                                               'g6-standard-2',      'and resized to the type the guest named, which it was not' );
    is( scalar asked_to( POST => '/v4/linode/instances' ),              0,                    'without a new Linode' );

    @ASKED = ();
    $hv->rebuild_guest( 'vm.test.test', image => 'linode/ubuntu24.04', size => 'g6-standard-2' );
    ($rebuilt) = map { $_->[2] } grep { $_->[1] =~ m{/rebuild\z} } @ASKED;
    ok( !exists $rebuilt->{type}, 'a guest already of the type it names is not resized' );

    like( exception { $hv->rebuild_guest( 'nope.test.test', image => 'linode/ubuntu24.04' ) }, qr/no[ ]guest[ ]called[ ]'nope\.test\.test'/, 'and one that is not there is said' );

    @ASKED = ();
    $STATE{busy} = 2;
    is( $hv->rebuild_guest( 'vm.test.test', image => 'linode/ubuntu24.04', size => 'g6-standard-2' )->{status}, 'running', 'a Linode still busy with the last thing is asked again until it is not' );
    is( scalar( grep { $_->[1] =~ m{/rebuild\z} } @ASKED ),                                                     3,         'twice refused, and the third time taken' );

    $STATE{busy} = 1_000_000;
    like( exception { $hv->rebuild_guest( 'vm.test.test', image => 'linode/ubuntu24.04', size => 'g6-standard-2' ) }, qr/400[ ]Linode[ ]busy/, 'and one still busy after BUSY_TIMEOUT is said' );
    $STATE{busy} = 0;
};

subtest 'provision_guest' => sub {
    reset_linode();
    my ( $ip, $out );
    $out = Capture::Tiny::capture_stdout( sub { $ip = linode_hv()->provision_guest( config_for('new.test.test'), { 'user-data' => "#cloud-config\n" } ) } );
    is( $ip, '203.0.113.20', 'a new guest comes back at its public address' );
    like( $out, qr/Asking[ ]Linode[ ]in[ ]us-east[ ]for[ ]new\.test\.test/, 'saying where it was asked for' );
};

subtest 'annihilate_domain' => sub {
    reset_linode();
    my $id = add_linode( label => 'vm.test.test' );
    $STATE{volumes}{$id} = [ { id => 7, label => 'vm-data' } ];
    my $hv = linode_hv();

    my ( $warned, $gone ) = warned( sub { $hv->annihilate_domain('vm.test.test') } );
    is( $gone, 1, 'a guest that is there is deleted' );
    ok( !$hv->domain_exists('vm.test.test'), 'and is gone' );
    like( $warned, qr/Kept[ ]the[ ]volume[ ]vm-data[ ]\(7\)/, 'a volume that was attached to it is kept, and named' );
    is( $hv->annihilate_domain('vm.test.test'), 0, 'and a guest that is gone already is not an error' );

    add_linode( label => 'stuck.test.test', stuck => 1 );
    like( exception { $hv->annihilate_domain('stuck.test.test') }, qr/still[ ]listed[ ]1s[ ]after[ ]being[ ]deleted/, 'one Linode keeps listing is said, rather than claimed gone' );
};

subtest 'snapshots' => sub {
    reset_linode();
    my $id = add_linode( label => 'vm.test.test' );
    my $hv = linode_hv();

    is( $hv->create_snapshot( 'vm.test.test', 'first' ), 1, 'a snapshot is taken' );
    my @order = map { $_->[1] =~ s{\A/v4/linode/instances/\d+/?}{}r } grep { $_->[0] eq 'POST' } @ASKED;
    is_deeply( \@order, [qw{shutdown /v4/images boot}], 'with the guest down while its disk is captured, and booted after' );

    my ($image) = map { $_->[2] } asked_to( POST => '/v4/images' );
    is( $image->{disk_id},                   $id * 10,             'of its disk, not its swap' );
    is( $image->{description},               'vm.test.test@first', 'kept under the guest it was taken of' );
    is( linode_of('vm.test.test')->{status}, 'running',            'and the guest is up again before it returns' );

    # A private image's id holds a slash, which Linode::API sends as one from
    # 0.002 on.  So the image it waits for is asked for by id, rather than
    # found by listing every image the account has.
    my ($waited) = grep { $_->[0] eq 'GET' && $_->[1] =~ m{\A/v4/images/} } @ASKED;
    like( $waited->[1], qr{\A/v4/images/private/\d+\z}, 'the image it waits for is asked for by id, with its slash sent as one' );

    @ASKED = ();
    my $name = $hv->snapshot_before_rebuild('vm.test.test');
    like( $name, qr/\Abefore-reprovision-\d{4}-\d{2}-\d{2}-\d{6}\z/, 'the rollback point before a rebuild is one too' );
    is( scalar asked_to( POST => "/v4/linode/instances/$id/boot" ), 0, 'and leaves the guest down for the rebuild that follows' );

    is_deeply( [ $hv->snapshot_names('vm.test.test') ],    [ $name, 'first' ], 'snapshots are listed newest first' );
    is_deeply( [ $hv->snapshot_names('other.test.test') ], [],                 'and only those of the guest asked about' );
    is( $hv->snapshot_current_name('vm.test.test'), $name, 'and the newest is the current one' );

    @ASKED = ();
    is( $hv->revert_snapshot( 'vm.test.test', 'first' ), 1, 'a guest is put back on a snapshot' );
    my ($rebuilt) = map { $_->[2] } grep { $_->[1] =~ m{/rebuild\z} } @ASKED;
    like( $rebuilt->{image},                                            qr{\Aprivate/},                      'by a rebuild from its image' );
    like( exception { $hv->revert_snapshot( 'vm.test.test', 'nope' ) }, qr/no[ ]snapshot[ ]called[ ]'nope'/, 'and one that is not there is said' );

    $STATE{refuse_image} = 1;
    @ASKED = ();
    my ( $warned, $ok ) = warned( sub { $hv->create_snapshot( 'vm.test.test', 'refused' ) } );
    is( $ok, 0, 'a snapshot Linode will not take is not claimed' );
    like( $warned, qr/Could[ ]not[ ]snapshot[ ]vm[.]test[.]test/, 'it says so' );
    like( $warned, qr/post-image:[ ]400[ ]Image[ ]too[ ]large/,   'with what Linode said' );
    is( scalar asked_to( POST => "/v4/linode/instances/$id/boot" ), 1, 'and boots the guest it shut down' );

    like( exception { $hv->create_snapshot( 'nope.test.test', 'x' ) }, qr/no[ ]guest[ ]called/, 'and a guest that is not there has nothing to snapshot' );
};

subtest 'image_for_distro' => sub {
    is( linode_hv()->image_for_distro( Test::Distro->new( ubuntu => '24.04' ) ), 'linode/ubuntu24.04', 'the distribution and its version, run together, as Linode names its images' );
    is( linode_hv()->image_for_distro( Test::Distro->new( debian => '12' ) ),    'linode/debian12',    'whichever distribution it is' );
};

subtest 'check_linode_resources' => sub {
    reset_linode();
    my @distros = ( Test::Distro->new( ubuntu => '24.04' ) );
    my $in_use  = Test::MockModule->new('Trog::HV');
    $in_use->redefine( distros_in_use => sub { return @distros } );

    my $result = linode_hv()->check_linode_resources;
    ok( $result->{ok}, 'a region with the metadata service and an image for each distro that reads it' );
    like( $result->{what}, qr/from[ ]linode\/ubuntu24[.]04/, 'naming the image it builds from' );

    @distros = ( Test::Distro->new( ubuntu => '24.04' ), Test::Distro->new( arch => q{} ) );
    $result  = linode_hv( region => 'us-west' )->check_linode_resources;
    ok( !$result->{ok}, 'a region without it, and a second distro whose image does not read it' );
    like( $result->{what}, qr/no[ ]metadata[ ]service[ ]in[ ]us-west/,        'each named' );
    like( $result->{what}, qr/linode\/arch[ ]does[ ]not[ ]read[ ]cloud-init/, 'both of them' );

    @distros = ( Test::Distro->new( debian => '99' ) );
    like( linode_hv()->check_linode_resources->{what}, qr/no[ ]image[ ]'linode\/debian99'/, 'and a release Linode has no image of' );

    @distros = ( Test::Distro->new( ubuntu => '24.04' ) );
    my $in_config = Test::MockModule->new('Trog::HV');
    $in_config->redefine( globals_in_use => sub { return ('g1-bogus') } );
    $result = linode_hv( region => 'mars-1' )->check_linode_resources;
    like( $result->{what}, qr/no[ ]region[ ]'mars-1'/, 'as is a region Linode does not have' );
    like( $result->{what}, qr/no[ ]type[ ]'g1-bogus'/, 'and a type a guest names that Linode does not sell' );

    $STATE{refuse_token} = 1;
    $result = linode_hv()->check_linode_resources;
    like( $result->{what}, qr/Could[ ]not[ ]ask[ ]Linode/, 'a list Linode would not give is said, rather than read as a list without the region in it' );
    like( $result->{fix},  qr/401[ ]Invalid[ ]Token/,      'with what Linode said' );
};

subtest 'check_linode_budget' => sub {
    reset_linode();
    add_linode( label => 'a.test.test' );

    # What a guest costs is the type it names, so the check says what each type
    # the configuration names would add.
    my $in_config = Test::MockModule->new('Trog::HV');
    $in_config->redefine( globals_in_use => sub { return qw{g6-standard-2 g6-nanode-1} } );

    my $what = linode_hv()->check_linode_budget->{what};
    like( $what, qr/account[ ]costs[ ]24[.]00[ ]a[ ]month/, 'what the account costs' );
    like( $what, qr/g6-standard-2[ ]at[ ]24[.]00/,          'what a guest of each type the guests name costs' );
    like( $what, qr/g6-nanode-1[ ]at[ ]5[.]00/,             'each of them' );
    like( $what, qr/no[ ]monthly_budget[ ]caps[ ]it/,       'and that nothing caps it' );

    ok( linode_hv( monthly_budget => 48 )->check_linode_budget->{ok}, 'an account inside its budget' );

    my $result = linode_hv( monthly_budget => 24 )->check_linode_budget;
    ok( !$result->{ok}, 'and one that has reached it' );
    like( $result->{fix}, qr/raise[ ]monthly_budget/, 'with what to do about it' );

    $in_config->redefine( globals_in_use => sub { return () } );
    like( linode_hv()->check_linode_budget->{what}, qr/\Athe[ ]account[ ]costs[ ]24[.]00[ ]a[ ]month;/i, 'and a configuration naming no type says only what the account costs' );
};

subtest 'check_reachable' => sub {
    reset_linode();
    ok( linode_hv()->check_reachable->{ok}, 'a token that opens the API' );
};

subtest 'refusals' => sub {
    my $err = exception { linode_hv()->create_disk };
    like( $err,                                 qr/Trog::HV::Linode[ ]has[ ]no[ ]create_disk/, 'refused by name' );
    like( $err,                                 qr/gets[ ]the[ ]disk[ ]of[ ]its[ ]type/,       'in Linode\'s terms' );
    like( exception { linode_hv()->pool_path }, qr/no[ ]storage[ ]pool/,                       'or the cloud\'s where they are the same' );
    is_deeply( [ linode_hv()->debug_actions ], [], 'and nothing for bin/debug_boot to do' );
};

Test::NoWarnings::had_no_warnings();
done_testing();
