#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/hv-solusvm.t - Trog::HV::SolusVM: which half of the node's API it asks, how a
guest is built, reinstalled and torn down, and what is asked for each

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Cpanel::JSON::XS();

use FindBin::libs;

use SolusVM::Client();      ## no critic (ProhibitUnusedImports) -- loaded so that HTTP::Tiny, which it pulls in, is there to mock below
use Trog::HV();
use Trog::HV::SolusVM();
use Trog::Secrets();        ## no critic (ProhibitUnusedImports) -- mocked below
use Trog::Credentials();    ## no critic (ProhibitUnusedImports) -- mocked below

local $Trog::HV::SolusVM::POLL           = 0;
local $Trog::HV::SolusVM::BUILD_TIMEOUT  = 2;
local $Trog::HV::SolusVM::DELETE_TIMEOUT = 1;

# A stand-in for the node that keeps state, so that a wait for a state change
# has one to wait for, and records every request, so the assertions are about
# what was asked.  The client in front of it is the real SolusVM::Client: the
# path, the query, the body and the bearer token are all built by the module
# that will build them against a real node.
my ( %STATE, @ASKED );

sub reset_node {
    %STATE = (
        account   => { email => 'you@example.test', roles => [ { name => 'CLIENT' } ], limit_usage => { servers => undef } },
        projects  => [ { id => 34, name => 'The Bunker' } ],
        locations => [ { id => 8,  name => 'qa' } ],
        os_images => [
            { name => 'Debian', versions => [ { id => 28, version => '13' }, { id => 15, version => '12' } ] },
            { name => 'Ubuntu', versions => [ { id => 40, version => '24.04' } ] },
        ],
        plans => [
            { id => 2375, name => 'c8.d80.r1024 - Shared LVM', tokens_per_month => 0, params => { ram => 1024 * 1024 * 1024,     vcpu => 8, cores => 1, disk => 80 } },
            { id => 2335, name => 'c2.d40.r4096 - Shared LVM', tokens_per_month => 0, params => { ram => 4 * 1024 * 1024 * 1024, vcpu => 2, cores => 2, disk => 40 } },
        ],
        servers   => [],
        snapshots => {},
    );
    @ASKED = ();
    return;
}

# What the node answers, by verb and path below /api/v1.  A request nobody
# accounted for dies rather than escaping to the network, because a test that
# reaches a real management node passes for the wrong reason.
sub answer {
    my ( $method, $path, $body ) = @_;

    return { data => $STATE{account} } if $method eq 'GET' && $path eq '/account';

    return _page( $STATE{projects} )  if $method eq 'GET' && $path eq '/projects';
    return _page( $STATE{locations} ) if $method eq 'GET' && $path eq '/locations';
    return _page( $STATE{os_images} ) if $method eq 'GET' && $path eq '/os_images';

    return _page( $STATE{plans} )   if $method eq 'GET'  && $path =~ m{\A /projects/\d+/plans \z}x;
    return _page( $STATE{servers} ) if $method eq 'GET'  && $path =~ m{\A /projects/\d+/servers \z}x;
    return _create($body)           if $method eq 'POST' && $path =~ m{\A /projects/\d+/servers \z}x;

    if ( my ($id) = $path =~ m{\A /servers/(\d+) \z}x ) {
        return { data => _server($id) } if $method eq 'GET';
        return _delete($id)             if $method eq 'DELETE';
    }

    if ( my ($id) = $path =~ m{\A /servers/(\d+)/reinstall \z}x ) {
        return _reinstall( $id, $body ) if $method eq 'POST';
    }

    if ( my ($id) = $path =~ m{\A /servers/(\d+)/snapshots \z}x ) {
        return _page( $STATE{snapshots}{$id} // [] ) if $method eq 'GET';
        return { data => {} }                        if $method eq 'POST';
    }

    return { data => {} } if $method eq 'POST' && $path =~ m{\A /snapshots/\d+/revert \z}x;

    die "the fake node was asked for $method $path, which it does not answer\n";
}

sub _page ($rows) { return { data => $rows, meta => { current_page => 1, last_page => 1, total => scalar @{$rows} } } }

# Reading a server is what moves a reinstall along, so that the two waits in
# rebuild_guest each have something real to wait for: the node reports
# 'reinstalling' while it works -- a sixth value for a field the API reference
# documents five of -- and 'started' once it is done.
sub _server {
    my ($id) = @_;

    my ($found) = grep { $_->{id} == $id } @{ $STATE{servers} };
    return undef unless $found;

    if ( ( $found->{status} // q{} ) eq 'reinstalling' ) {
        my $was = { %{$found} };
        $found->{status} = 'started' if --$found->{busy_for} <= 0;
        return $was;
    }

    return $found;
}

sub _create {
    my ($body) = @_;

    my $made = {
        id           => 24596,
        name         => $body->{name},
        status       => 'started',
        ip_addresses => { ipv4 => [ { ip => '10.4.32.97', is_primary => 1 } ], ipv6 => [] },
    };
    push @{ $STATE{servers} }, $made;
    return { data => $made };
}

# A reinstall the node has taken but not begun still says started, which is
# what _wait_for_change is for: this says so once, then reports the state the
# node really reports while it works.
sub _reinstall {
    my ( $id, $body ) = @_;

    my ($server) = grep { $_->{id} == $id } @{ $STATE{servers} };
    @{$server}{qw{status busy_for}} = ( 'reinstalling', 2 );
    return { data => {} };
}

sub _delete {
    my ($id) = @_;
    @{ $STATE{servers} } = grep { $_->{id} != $id } @{ $STATE{servers} } unless $STATE{keep_deleted};
    return { data => {} };
}

my $transport = Test::MockModule->new('HTTP::Tiny');
$transport->redefine(
    request => sub {
        my ( $self, $method, $url, $args ) = @_;

        my ($path) = $url =~ m{\A https://[^/]+ /api/v1 ( [^?]* ) }x;
        my $body = $args->{content} ? Cpanel::JSON::XS->new->utf8->decode( $args->{content} ) : undef;
        push @ASKED, { method => $method, path => $path, url => $url, body => $body, headers => $args->{headers} // {} };

        my $answered = answer( $method, $path, $body );
        my $json     = Cpanel::JSON::XS->new->utf8->canonical;
        return {
            status  => 200,
            reason  => 'OK',
            success => 1,
            headers => { 'content-type' => 'application/json' },
            content => $json->encode($answered),
        };
    }
);

# The token is a secret: reference, which is the only shape the backend takes.
my $secrets = Test::MockModule->new('Trog::Secrets');
$secrets->redefine(
    lookup => sub {
        my ( $class, $file, $pass, %want ) = @_;
        return map { $_ => 'a-token' } keys %want;
    }
);
my $credentials = Test::MockModule->new('Trog::Credentials');
$credentials->redefine( prompt => sub { return 'hunter2' } );

sub node {
    my (%opts) = @_;
    reset_node() unless delete $opts{keep_state};
    return Trog::HV::SolusVM->build(
        solusvm          => 'solus.example.test',
        solusvm_token    => 'secret:solusvm/api/password',
        solusvm_location => 8,
        %opts,
    );
}

sub asked_for {
    my ( $method, $path ) = @_;
    return grep { $_->{method} eq $method && $_->{path} eq $path } @ASKED;
}

subtest 'a block has to name a node and a token' => sub {
    like exception { Trog::HV::SolusVM->build( solusvm_token => 'secret:a/b/c' ) }, qr/needs[ ]'solusvm'/,
      'a block with no management node in it is not a SolusVM hypervisor';

    like exception { Trog::HV::SolusVM->build( solusvm => 'a.test' ) }, qr/needs[ ]solusvm_token/,
      'and one with no token cannot ask it anything';

    like exception { Trog::HV::SolusVM->build( solusvm => 'a.test', solusvm_token => 'the-token-itself' ) }, qr/has[ ]to[ ]be[ ]a[ ]secret:[ ]reference/,
      'a token written out in the open is refused rather than used, since it does not expire';
};

subtest 'which kind of thing it is' => sub {
    my $hv = node();

    is Trog::HV::SolusVM->marker,   'solusvm',      'the marker key is the node name';
    is Trog::HV::SolusVM->size_key, 'solusvm_plan', 'and a guest says its own size';
    is_deeply [ Trog::HV::SolusVM->client_module ], [ 'SolusVM::Client', '0.001' ], 'it talks to the node through the CPAN client';

    is Trog::HV->backend_for( solusvm => 'a.test' ), 'Trog::HV::SolusVM', 'a block naming a node gets this backend';

    ok $hv->is_local,          'there is no node filesystem to reach, so file operations are local ones';
    ok $hv->builds_by_api,     'a guest is asked for, not defined';
    ok $hv->manages_addresses, 'and the node hands out the address';

    is $hv->describe, 'the SolusVM node solus.example.test', 'it says where it builds';
    is $hv->uri,      'https://solus.example.test/api/v1',   'and where that is';

    like exception { $hv->cloudinit_iso }, qr/has[ ]no[ ]cloudinit_iso/, 'the libvirt nouns are refused, by Trog::HV::Cloud rather than here';
};

subtest 'the project is where the API answers' => sub {
    is node( solusvm_project => 12 )->project, 12, 'a project named in the file is the one';
    is node()->project,                        34, 'and where the account has exactly one, that is the one';

    my $hv = node();
    $STATE{projects} = [ { id => 1, name => 'one' }, { id => 2, name => 'two' } ];
    my $err = exception { $hv->project };
    like $err, qr/has[ ]2[ ]projects/,         'several means one has to be named';
    like $err, qr/one[ ]\(1\),[ ]two[ ]\(2\)/, 'and the error says which are on offer';

    $hv = node();
    $STATE{projects} = [];
    like exception { $hv->project }, qr/no[ ]projects/, 'none means there is nowhere to build';
};

subtest 'what the node sells' => sub {
    my $hv = node();

    is $hv->plan(2375)->{id},                        2375, 'a plan is found by id';
    is $hv->plan('c2.d40.r4096 - Shared LVM')->{id}, 2335, 'and by name, which is what a person writes';
    like exception { $hv->plan('nonesuch') }, qr/no[ ]plan[ ]'nonesuch'/, 'and one the node does not sell is refused by name';

    my $cheapest = $hv->cheapest_for( memory_mb => 512, cpus => 1, disk_bytes => 10 * 1024 * 1024 * 1024 );
    is $cheapest->{key},   'solusvm_plan', 'an offer names the key the guest would set';
    is $cheapest->{value}, 2375,           'and the smallest plan that holds it, every plan here costing nothing';

    $cheapest = $hv->cheapest_for( memory_mb => 2048 );
    is $cheapest->{value}, 2335, 'a guest too big for the small one is offered the next';

    is $hv->cheapest_for( memory_mb => 1024 * 1024 ), undef, 'and one too big for anything is offered nothing';
};

subtest 'an image is a version, not an image' => sub {
    my $hv = node();

    is $hv->image_for_distro( FakeDistro->new( 'debian', '13' ) ),    28, 'the id belongs to the version, not to Debian';
    is $hv->image_for_distro( FakeDistro->new( 'ubuntu', '24.04' ) ), 40, 'whichever image it is under';

    like exception { $hv->image_for_distro( FakeDistro->new( 'debian', '99' ) ) }, qr/no[ ]debian[ ]99[ ].*Debian[ ]13/xs,
      'a release the node does not have lists the ones it does, since an id cannot be guessed';
};

subtest 'capacity is the plan the guest named' => sub {
    my $hv = node();

    my $have = $hv->capacity( solusvm_plan => 2375 );
    is $have->{memory_mb}, 1024,                    "the plan's memory, in MB out of the bytes the node reports";
    is $have->{cpus},      8,                       'its vcpus';
    is $have->{disk_free}, 80 * 1024 * 1024 * 1024, 'and its disk, in bytes out of the gigabytes';
    is $have->{guests},    0,                       'with the project counted for the guest count';

    is $hv->reserve_memory, 0, 'no reserve is held back from a plan that is sold whole';
    is $hv->cpu_overcommit, 1, 'and a plan is already what you may run';

    like exception { $hv->capacity() }, qr/names[ ]none/, 'a guest that named no plan has no capacity to report';

    is_deeply [ $hv->shortfalls( memory_mb => 512, cpus => 2, disk_bytes => 1024 ) ], [], 'a guest the plan is big enough for fits'
      if $hv->shortfalls( solusvm_plan => 2375, memory_mb => 512, cpus => 2, disk_bytes => 1024 );

    is_deeply [ $hv->shortfalls( memory_mb => 512 ) ], ['names no solusvm_plan, so it is not built on a SolusVM node'],
      'and a guest that names no plan is simply not built here';
};

subtest 'finding a guest by name' => sub {
    my $hv = node();
    $STATE{servers} = [ { id => 21995, name => 'one.test' }, { id => 16668, name => 'two.test' } ];

    is_deeply [ sort $hv->guest_names ], [qw{one.test two.test}], 'every server in the project, whatever built it';
    ok $hv->domain_exists('one.test'), 'a guest that is there';
    ok !$hv->domain_exists('no.test'), 'and one that is not';

    $STATE{servers} = [ { id => 1, name => 'same.test' }, { id => 2, name => 'same.test' } ];
    like exception { $hv->server('same.test') }, qr/2[ ]servers[ ]called[ ]'same.test'/,
      'two of a name is refused rather than guessed between, because the next thing done with the answer deletes it';
};

subtest 'the address a guest is reached at' => sub {
    my $hv = node();
    $STATE{servers} = [ { id => 1, name => 'one.test', status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.98' }, { ip => '10.4.32.49', is_primary => 1 } ] } } ];
    is $hv->guest_ssh_ip('one.test'), '10.4.32.49', 'the primary address, which is the one the node itself shows';

    $STATE{servers} = [ { id => 1, name => 'one.test', status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.98' } ] } } ];
    is $hv->guest_ssh_ip('one.test'), '10.4.32.98', 'or the only one, where the node marked none of them';

    $STATE{servers} = [ { id => 1, name => 'one.test', status => 'processing', ip_addresses => { ipv4 => [] } } ];
    like exception { $hv->guest_ssh_ip('one.test') }, qr/no[ ]IPv4[ ]address[ ].*[ ]processing/xs,
      'a guest with no address yet says what it is doing instead of handing back nothing';
};

subtest 'building a guest' => sub {
    my $hv = node();

    my $made = $hv->create_guest( name => 'new.test', image => 28, size => 2375, user_data => "#cloud-config\n" );
    is $made->{id}, 24596, 'the server comes back, having been waited for';

    my ($asked) = asked_for( 'POST', '/projects/34/servers' );
    is_deeply $asked->{body},
      {
        name                => 'new.test',
        plan_id             => 2375,
        location_id         => 8,
        os_image_version_id => 28,
        user_data           => "#cloud-config\n",
      },
      "the project endpoint's own field names, which are not the node-wide endpoint's";

    is $asked->{headers}{Authorization}, 'Bearer a-token', 'carrying the token out of the store';

    like exception { $hv->create_guest( name  => 'x.test', size  => 2375 ) }, qr/needs[ ]an[ ]image/, 'a guest with no image is refused';
    like exception { $hv->create_guest( name  => 'x.test', image => 28 ) },   qr/needs[ ]a[ ]size/,   'and one with no plan';
    like exception { $hv->create_guest( image => 28,       size  => 2375 ) }, qr/needs[ ]a[ ]name/,   'and one with no name';
};

subtest 'reinstalling one that is already there' => sub {
    my $hv = node();
    $STATE{servers} = [ { id => 21995, name => 'one.test', status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.49', is_primary => 1 } ] } } ];

    $hv->rebuild_guest( 'one.test', image => 28, user_data => "#cloud-config\nkey\n" );

    my ($asked) = asked_for( 'POST', '/servers/21995/reinstall' );
    is_deeply $asked->{body}, { os => 28, user_data => "#cloud-config\nkey\n" },
      "reinstall calls 'os' what create calls 'os_image_version_id', and the payload is why this is not a delete and a rebuild";

    ok scalar( grep { $_->{method} eq 'GET' && $_->{path} eq '/servers/21995' } @ASKED ) > 1,
      'it waits for the node to stop saying started before waiting for it to say started again';

    like exception { $hv->rebuild_guest( 'gone.test', image => 28 ) }, qr/no[ ]guest[ ]called[ ]'gone.test'/, 'and there has to be one to reinstall';
    like exception { $hv->rebuild_guest('one.test') },                 qr/needs[ ]an[ ]image/,                'and an image to put back on it';
};

subtest 'taking one away' => sub {
    my $hv = node();
    $STATE{servers} = [ { id => 21995, name => 'one.test' } ];

    ok $hv->annihilate_domain('one.test'),                'a guest that was there is deleted';
    ok scalar( asked_for( 'DELETE', '/servers/21995' ) ), 'by its id';

    is $hv->annihilate_domain('one.test'), 0, 'and asking again is false rather than fatal, so a teardown can be run twice';

    $STATE{servers}      = [ { id => 1, name => 'stuck.test' } ];
    $STATE{keep_deleted} = 1;
    like exception { $hv->annihilate_domain('stuck.test') }, qr/still[ ]listed[ ]1s[ ]after[ ]being[ ]deleted/,
      'a delete the node accepted and did not carry out is said to be that, rather than waited on forever';
};

subtest 'preflight' => sub {
    my $hv = node();

    is_deeply [ $hv->preflight_checks ],
      [qw{check_client check_reachable check_solusvm_resources check_solusvm_quota check_rsync check_transfer_ip check_transfer_route check_fetch_sources check_config}],
      'the checks are asked in an order where the client and the credential come first';

    my $reachable = $hv->check_reachable;
    ok $reachable->{ok}, 'a token that works is reachable';
    like $reachable->{what}, qr/you\@example[.]test[ ]\(CLIENT\)/, 'and says who it is, and what it may do';

    my $resources = $hv->check_solusvm_resources;
    ok $resources->{ok}, 'a project and a location that exist is a pass';
    like $resources->{what}, qr/project[ ]34[ ]at[ ]location[ ]8/, 'said in the words somebody would recognise';

    my $wrong = node( solusvm_location => 'moon' );
    ok !$wrong->check_solusvm_resources->{ok}, 'a location the node does not have is a failure';

    my $quota = $hv->check_solusvm_quota;
    ok $quota->{ok}, 'an account with no limit has room';
    like $quota->{what}, qr/no[ ]limit[ ]the[ ]node[ ]will[ ]tell[ ]us[ ]about/, 'and says that rather than inventing a number';

    my $full = node( max_guests => 1 );
    $STATE{servers} = [ { id => 1, name => 'a.test' } ];
    ok !$full->check_solusvm_quota->{ok}, 'and one at its limit has not';
};

{

    package FakeDistro;
    sub new { my ( $class, $distribution, $release ) = @_; return bless { distribution => $distribution, release => $release }, $class }
    sub distribution    ($self) { return $self->{distribution} }
    sub release_version ($self) { return $self->{release} }
}

Test::NoWarnings::had_no_warnings();
done_testing();
