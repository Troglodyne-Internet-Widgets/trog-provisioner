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

local $Trog::HV::Linode::POLL          = 0;
local $Trog::HV::Linode::BUILD_TIMEOUT = 2;
local $Trog::HV::Linode::IMAGE_TIMEOUT = 2;

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
    $r->get('/v4/regions')->to( cb => sub ($c) { $asked->($c); $page->( $c, @{ $STATE{regions} } ) } );
    $r->get('/v4/images')->to(
        cb => sub ($c) {
            $asked->($c);
            my @shown = map {
                { %$_ }
            } @{ $STATE{images} };
            $_->{status} = 'available' for @{ $STATE{images} };    # the next look finds them captured
            $page->( $c, @shown );
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
            $page->( $c, grep { !defined $filter->{label} || $_->{label} eq $filter->{label} } @{ $STATE{linodes} } );
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
            $linode->{status} = $linode->{becomes} // 'running' if $TRANSIENT{ $linode->{status} };
            $c->render( json => $shown );
        }
    );

    $r->post('/v4/linode/instances/:id/rebuild')->to(
        cb => sub ($c) {
            $asked->($c);
            my $linode = $find->($c);
            @$linode{qw{status becomes}} = qw{rebuilding running};
            $linode->{type} = $c->req->json->{type} if $c->req->json->{type};
            $c->render( json => $linode );
        }
    );

    $r->post('/v4/linode/instances/:id/shutdown')->to( cb => sub ($c) { $asked->($c); my $l = $find->($c); @$l{qw{status becomes}} = qw{shutting_down offline}; $c->render( json => {} ) } );
    $r->post('/v4/linode/instances/:id/boot')->to( cb => sub ($c) { $asked->($c); my $l = $find->($c); @$l{qw{status becomes}} = qw{booting running}; $c->render( json => {} ) } );

    $r->delete('/v4/linode/instances/:id')->to(
        cb => sub ($c) {
            $asked->($c);
            @{ $STATE{linodes} } = grep { $_->{id} != $c->param('id') } @{ $STATE{linodes} };
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
    return Trog::HV::Linode->build( linode_token => 'secret:linode/api/password', region => 'us-east', type => 'g6-standard-2', image => 'linode/ubuntu24.04', %opts );
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
    $config->param( domain => $domain );
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
    $secrets->redefine( lookup => sub ( $class, $file, $password, %needed ) { %asked = ( file => $file, password => $password, %needed ); return ( token => 'the-token' ) } );
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( prompt => sub ( $class, $message, $name, @ ) { return "passphrase for $name" } );

    is( linode_hv()->_token, 'the-token',                  'the token comes out of the secret store' );
    is( $asked{token},       'secret:linode/api/password', 'by the reference the block names' );
    is( $asked{password},    'passphrase for keepass',     'unlocked with the passphrase this run has for it' );
};

subtest 'monthly_cost and monthly_spend' => sub {
    reset_linode();
    is( linode_hv()->monthly_cost( memory_mb => 1 ),   24,   'the type\'s price, whatever the guest asks for' );
    is( linode_hv( region => 'br-gru' )->monthly_cost, 28.8, 'in the region, where the region prices it differently' );
    like( exception { linode_hv( type => undef )->monthly_cost },      qr/Say[ ]which[ ]type[ ]and[ ]region/, 'and no price without a type' );
    like( exception { linode_hv( type => 'g1-bogus' )->monthly_cost }, qr/no[ ]type[ ]'g1-bogus'/,            'nor for a type Linode does not sell' );

    add_linode( label => 'a.test.test' );
    add_linode( label => 'b.test.test', type   => 'g6-nanode-1', backups => { enabled => Cpanel::JSON::XS::true() } );
    add_linode( label => 'c.test.test', region => 'br-gru' );
    is( linode_hv()->monthly_spend, 24 + 5 + 2 + 28.8, 'the account is every Linode on it, with backups where they are on, at its region\'s price' );
};

subtest 'capacity and shortfalls' => sub {
    reset_linode();
    add_linode( label => 'a.test.test' );
    my $hv = linode_hv( monthly_budget => 60 );

    is_deeply(
        $hv->capacity,
        {
            memory_mb => 4096, memory_committed => 0, memory_free    => 4096,
            cpus      => 2,    cpus_allocatable => 2, cpus_committed => 0, cpus_free => 2,
            disk_free => 81920 * 1024 * 1024,
            guests    => 1,
        },
        'one guest of the type, nothing committed against it, and the Linodes on the account',
    );

    is_deeply( [ $hv->shortfalls( memory_mb => 4096, cpus => 2, disk_bytes => 40 * 1024**3 ) ], [], 'a guest the type holds, inside the budget, fits' );

    my @short = $hv->shortfalls( memory_mb => 8192, cpus => 2, disk_bytes => 40 * 1024**3 );
    like( $short[0], qr/needs[ ]8192MB[ ]of[ ]memory,[ ]4096MB[ ]free/, 'a guest bigger than the type does not' );

    $hv    = linode_hv( monthly_budget => 40 );
    @short = $hv->shortfalls( memory_mb => 1024, cpus => 1, disk_bytes => 1 );
    is( scalar @short, 1, 'nor does one that would go over the budget' );
    like( $short[0], qr/g6-standard-2[ ]costs[ ]24[.]00[ ]a[ ]month/, 'saying what the guest costs' );
    like( $short[0], qr/already[ ]costs[ ]24[.]00/,                   'and what the account does' );
    like( $short[0], qr/monthly_budget[ ]of[ ]40[.]00/,               'against its budget' );

    is( linode_hv( monthly_budget => 48 )->shortfalls( memory_mb => 1024 ),                  0, 'and exactly the budget is inside it' );
    is( linode_hv()->reserve_memory + linode_hv()->reserve_cpus + linode_hv()->reserve_disk, 0, 'no reserve, because there is no host to keep one for' );
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

    my $linode = $hv->create_guest( name => 'new.test.test', user_data => "#cloud-config\n" );
    is( $linode->{status}, 'running', 'it waits until Linode says the guest is running' );

    my ($created) = asked_to( POST => '/v4/linode/instances' );
    my $body = $created->[2];
    is( $body->{label},       'new.test.test',      'labeled with the domain' );
    is( $body->{region},      'us-east',            'in the region of the block' );
    is( $body->{type},        'g6-standard-2',      'of its type' );
    is( $body->{image},       'linode/ubuntu24.04', 'from its image' );
    is( $body->{firewall_id}, 42,                   'behind its firewall' );
    ok( $body->{private_ip}, 'with a private address, as asked' );
    is_deeply( $body->{tags}, ['trog-provisioner'], 'tagged as ours' );
    is( MIME::Base64::decode_base64( $body->{metadata}{user_data} ), "#cloud-config\n", 'with the seed for the metadata service' );
    like( $body->{root_pass}, qr/\A\S{48}\z/, 'and a long random root password, which Linode requires' );

    reset_linode();
    linode_hv()->create_guest( name => 'again.test.test' );
    isnt( ( asked_to( POST => '/v4/linode/instances' ) )[0][2]{root_pass}, $body->{root_pass}, 'a different one each time' );

    like( exception { linode_hv( image => undef )->create_guest( name => 'x.test.test' ) }, qr/needs[ ]'image'/, 'no image is said, not sent' );
    like( exception { linode_hv()->create_guest( name => 'big.test.test', user_data => 'x' x 65536 ) }, qr/65536[ ]bytes/,   'nor a payload over what the metadata service takes' );
    like( exception { linode_hv()->create_guest( name => 'x' x 65 ) },                                  qr/64[ ]characters/, 'nor a label Linode would refuse' );

    reset_linode();
    like( exception { linode_hv()->create_guest( name => 'ab' ) }, qr/Linode[ ]refused[ ]post-linode-instance:[ ]400[ ]\/body/, 'a body the specification refuses is refused before it is sent' );
    is( scalar asked_to( POST => '/v4/linode/instances' ), 0, 'and nothing was sent' ) or diag explain \@ASKED;
};

subtest 'rebuild_guest' => sub {
    reset_linode();
    add_linode( label => 'vm.test.test', type => 'g6-nanode-1' );
    my $hv = linode_hv();

    my $linode = $hv->rebuild_guest( 'vm.test.test', user_data => "#cloud-config\n" );
    is( $linode->{status}, 'running', 'it waits until the rebuilt guest is running' );

    my ($rebuilt) = map { $_->[2] } grep { $_->[1] =~ m{/rebuild\z} } @ASKED;
    is( $rebuilt->{image},                                              'linode/ubuntu24.04', 'onto the image of the block' );
    is( MIME::Base64::decode_base64( $rebuilt->{metadata}{user_data} ), "#cloud-config\n",    'with the new seed' );
    is( $rebuilt->{type},                                               'g6-standard-2',      'and resized to the type of the block, which it was not' );
    is( scalar asked_to( POST => '/v4/linode/instances' ),              0,                    'without a new Linode' );

    @ASKED = ();
    $hv->rebuild_guest('vm.test.test');
    ($rebuilt) = map { $_->[2] } grep { $_->[1] =~ m{/rebuild\z} } @ASKED;
    ok( !exists $rebuilt->{type}, 'a guest of the right type is not resized' );

    like( exception { $hv->rebuild_guest('nope.test.test') }, qr/no[ ]guest[ ]called[ ]'nope\.test\.test'/, 'and one that is not there is said' );
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
    is( linode_of('vm.test.test')->{status}, 'booting',            'and the guest is on its way back up' );

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

subtest 'check_linode_resources' => sub {
    reset_linode();
    ok( linode_hv()->check_linode_resources->{ok}, 'a region with the metadata service and an image that reads it' );

    my $result = linode_hv( region => 'us-west', image => 'linode/arch' )->check_linode_resources;
    ok( !$result->{ok}, 'a region without it and an image that does not read it' );
    like( $result->{what}, qr/no[ ]metadata[ ]service[ ]in[ ]us-west/,        'each named' );
    like( $result->{what}, qr/linode\/arch[ ]does[ ]not[ ]read[ ]cloud-init/, 'both of them' );

    $result = linode_hv( type => 'g1-bogus', region => 'mars-1' )->check_linode_resources;
    like( $result->{what}, qr/no[ ]region[ ]'mars-1',[ ]no[ ]type[ ]'g1-bogus'/, 'as are a region and a type Linode does not have' );

    like( linode_hv( image => undef )->check_linode_resources->{what}, qr/Not[ ]configured:[ ]image/, 'and one the block does not name' );
};

subtest 'check_linode_budget' => sub {
    reset_linode();
    add_linode( label => 'a.test.test' );

    my $what = linode_hv()->check_linode_budget->{what};
    like( $what, qr/a[ ]guest[ ]here[ ]24[.]00[ ]more/, 'without a budget, what a guest costs' );
    like( $what, qr/no[ ]monthly_budget[ ]caps[ ]it/,   'and that nothing caps it' );
    ok( linode_hv( monthly_budget => 48 )->check_linode_budget->{ok}, 'a guest that fits the budget' );

    my $result = linode_hv( monthly_budget => 47 )->check_linode_budget;
    ok( !$result->{ok}, 'and one that does not' );
    like( $result->{fix}, qr/raise[ ]monthly_budget/, 'with what to do about it' );
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
