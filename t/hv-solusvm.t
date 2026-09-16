#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/hv-solusvm.t - Trog::HV::SolusVM: what a management node answers, and which of
its two halves this asks

=cut

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use File::Temp();
use Config::Simple();

## no critic (CompileTime) -- it has to be set before anything reads it.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use FindBin::libs;

use Trog::HV();
use Trog::HV::SolusVM();

# Stands in for SolusVM::Client.  The shapes here are the ones a real node
# answered with -- the {data} envelope on everything singular, addresses under
# ip_addresses.ipv4 rather than on the listing, and a plan's ram in bytes while
# its disk is in gigabytes -- because a fake that tidied those up would let code
# pass here that cannot work against the node.
{

    package Test::FakeNode;

    sub new {
        my ( $class, %state ) = @_;
        return bless {
            calls     => [],
            projects  => [ { id => 34, name => 'The Bunker' } ],
            servers   => [],
            plans     => [],
            locations => [ { id   => 8,        name     => 'qa' } ],
            os_images => [ { name => 'Debian', versions => [ { id => 28, version => '13' }, { id => 15, version => '12' } ] } ],
            snapshots => {},
            account   => { email => 'you@example.test', roles => [ { name => 'CLIENT' } ], limit_usage => { servers => undef } },
            %state,
        }, $class;
    }

    sub _record {
        my ( $self, $what, %args ) = @_;
        push @{ $self->{calls} }, [ $what, \%args ];
        return;
    }

    sub calls_to {
        my ( $self, $what ) = @_;
        return grep { $_->[0] eq $what } @{ $self->{calls} };
    }

    # Every listing goes through paginate, because a listing that stopped at
    # page one is how a plan on page two becomes "there is no such plan".
    sub paginate {
        my ( $self, $operation, %params ) = @_;
        $self->_record( $operation => %params );

        return @{ $self->{projects} }                       if $operation eq 'get_list_of_projects';
        return @{ $self->{locations} }                      if $operation eq 'get_list_of_locations';
        return @{ $self->{os_images} }                      if $operation eq 'get_list_of_os_images';
        return @{ $self->{plans} }                          if $operation eq 'get_list_of_project_plans';
        return @{ $self->{servers} }                        if $operation eq 'get_list_of_project_servers';
        return @{ $self->{snapshots}{ $params{id} } // [] } if $operation eq 'get_list_of_server_snapshots';

        die "the fake node was asked to paginate $operation, which it does not know about\n";
    }

    sub get_user_info { return { data => $_[0]->{account} } }

    sub get_an_existing_server {
        my ( $self, %args ) = @_;
        $self->_record( get_an_existing_server => %args );

        my ($server) = grep { $_->{id} == $args{id} } @{ $self->{servers} };
        return { data => $server };
    }

    sub create_a_new_project_server {
        my ( $self, %args ) = @_;
        $self->_record( create_a_new_project_server => %args );

        my $made = { id => 24595, name => $args{name}, status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.97', is_primary => 1 } ] } };
        push @{ $self->{servers} }, $made;
        return { data => $made };
    }

    sub reinstall_server { my ( $self, %args ) = @_; $self->_record( reinstall_server => %args ); return { data => {} } }

    # A delete the node accepts and then does not carry out looks exactly like
    # a slow one until the wait runs out, which is the case worth having a fake
    # for: `keep` is that node.
    sub delete_server {
        my ( $self, %args ) = @_;
        $self->_record( delete_server => %args );
        @{ $self->{servers} } = grep { $_->{id} != $args{id} } @{ $self->{servers} } unless $self->{keep};
        return { data => {} };
    }
    sub create_a_new_server_snapshot { my ( $self, %args ) = @_; $self->_record( create_a_new_server_snapshot => %args ); return { data => {} } }
    sub revert_snapshot              { my ( $self, %args ) = @_; $self->_record( revert_snapshot              => %args ); return { data => {} } }
}

my $FAKE;
my $mock = Test::MockModule->new('Trog::HV::SolusVM');
$mock->redefine( api => sub { return $FAKE } );

sub node {
    my (%opts) = @_;
    $FAKE = delete $opts{node} // Test::FakeNode->new;
    return Trog::HV::SolusVM->build( solusvm => 'solus.example.test', token => 'a-token', %opts );
}

my %PLAN = ( id => 2375, name => 'c8.d80.r1024 - Shared LVM', params => { ram => 1073741824, vcpu => 8, cores => 1, disk => 80 } );

subtest 'a node has to be named' => sub {
    like exception { Trog::HV::SolusVM->build() }, qr/needs a 'solusvm'/,
      'a block with no management node in it is not a SolusVM hypervisor';

    my $hv = node();
    is $hv->host,     'solus.example.test',                  'it remembers the node';
    is $hv->describe, 'the SolusVM node solus.example.test', 'and says so when something prints where it is building';
    is $hv->uri,      'https://solus.example.test/api/v1',   'with something true to print for a URI';
};

subtest 'which kind of thing it is' => sub {
    my $hv = node();

    ok $hv->is_local,          'there is no node filesystem to reach, so file operations are local ones';
    ok $hv->builds_by_api,     'a guest is asked for, not defined';
    ok $hv->manages_addresses, 'and the node hands out the address, so the ip pool has nothing to allocate';

    my %keys = Trog::HV::SolusVM->config_keys;
    is $keys{solusvm}, 'solusvm',       'the marker key is its own name';
    is $keys{plan},    'solusvm_plan',  'and everything else is prefixed, since a provision.conf is read by every backend at once';
    is $keys{token},   'solusvm_token', 'including the token';
};

subtest 'the token is the whole credential' => sub {
    my $hv = node( token => 'a-token' );
    is $hv->token, 'a-token', 'a token written out is used as it is';

    like exception { node( token => undef )->token }, qr/No token for the SolusVM node/,
      'and a node with none says which key is missing';

    my $secrets = Test::MockModule->new('Trog::Secrets');
    my @asked;
    $secrets->redefine(
        read => sub {
            my ( $class, $file, $password, %needed ) = @_;
            push @asked, \%needed;
            return ( secret => 'out-of-the-store' );
        }
    );
    my $credentials = Test::MockModule->new('Trog::Credentials');
    $credentials->redefine( prompt => sub { return 'hunter2' } );

    my $referring = node( token => 'secret:solusvm/qa/password' );
    is $referring->token, 'out-of-the-store', 'a secret: reference is resolved out of the store';
    is_deeply \@asked, [ { secret => 'secret:solusvm/qa/password' } ], 'by the reference it was given';

    is $referring->token, 'out-of-the-store', 'and kept, so one run is one password prompt';
    is scalar @asked,     1,                  'rather than one per question asked of the node';

    like exception { node( token => 'secret:nonsense' )->token }, qr/Malformed secret/,
      'a reference written wrong is an error now, not when the store is opened';
};

subtest 'the project is where the API answers' => sub {
    is node( project => 12 )->project, 12, 'a project named in the file is the one';

    is node()->project, 34, 'and where the account has exactly one, that is the one';

    my $several = Test::FakeNode->new( projects => [ { id => 1, name => 'one' }, { id => 2, name => 'two' } ] );
    my $err     = exception { node( node => $several )->project };
    like $err, qr/has 2 projects/,       'several means one has to be named';
    like $err, qr/one \(1\), two \(2\)/, 'and the error says which are on offer';

    my $none = Test::FakeNode->new( projects => [] );
    like exception { node( node => $none )->project }, qr/no projects/, 'none means there is nowhere to build';
};

subtest 'a plan and a location, by name or by id' => sub {
    my $with_plan = Test::FakeNode->new( plans => [ \%PLAN ] );

    is node( node => $with_plan, plan => 'c8.d80.r1024 - Shared LVM' )->plan_detail->{id}, 2375, 'a plan is found by name';
    is node( node => $with_plan, plan => 2375 )->plan_detail->{id},                        2375, 'and by id';

    my $hv = node( node => Test::FakeNode->new( plans => [ \%PLAN ] ), plan => 'nonesuch' );
    like exception { $hv->plan_detail }, qr/no plan 'nonesuch'/, 'and one the node does not have is refused by name';

    like exception { node()->plan_detail }, qr/needs a plan/, 'a hypervisor with no plan configured says which key to set';

    is node( location => 'qa' )->location_id, 8, 'a location is found by name too';
    is node( location => 8 )->location_id,    8, 'and by id';

    like exception { node( location => 'moon' )->location_id }, qr/no location 'moon'.*qa \(8\)/s,
      'and a wrong one lists what there is';
};

subtest 'capacity is the plan, and the count is the limit' => sub {
    my $node = Test::FakeNode->new(
        plans   => [ \%PLAN ],
        servers => [ { id => 1, name => 'a.test' }, { id => 2, name => 'b.test' } ],
    );
    my $hv = node( node => $node, plan => 2375 );

    my $have = $hv->capacity;
    is $have->{memory_mb}, 1024,                    "the plan's memory, in MB, out of the bytes the node reports";
    is $have->{cpus},      8,                       'its vcpus';
    is $have->{disk_free}, 80 * 1024 * 1024 * 1024, 'and its disk, in bytes out of the gigabytes';
    is $have->{guests},    2,                       'the guest count is the project, counted';

    is $have->{memory_free}, 1024, 'nothing is committed against a plan, so free is the whole of it';
    is $hv->reserve_memory,  0,    'and no reserve is held back from a plan that is sold whole';
    is $hv->cpu_overcommit,  1,    'a plan is already what you may run, so there is nothing to overcommit';

    is_deeply [ $hv->shortfalls( memory_mb => 512, cpus => 2, disk_bytes => 10 * 1024 * 1024 * 1024 ) ], [],
      'a guest the plan is big enough for fits';

    my ($reason) = $hv->shortfalls( memory_mb => 4096 );
    like $reason, qr/needs 4096MB of memory, 1024MB free/, 'and one it is not says so in the same words every backend uses';

    is $hv->max_guests, 0, 'an account in no limit group has no cap this tool will invent one for';

    my $limited = Test::FakeNode->new( plans => [ \%PLAN ], account => { email => 'x@example.test', roles => [], limit_usage => { servers => 5 } } );
    is node( node => $limited, plan => 2375 )->max_guests, 5, 'and one that has a limit is capped by it';

    is node( node => Test::FakeNode->new( plans => [ \%PLAN ] ), plan => 2375, max_guests => 2 )->max_guests, 2,
      'hypervisors.conf can lower that';
};

subtest 'finding a guest by name' => sub {
    my $node = Test::FakeNode->new( servers => [ { id => 21995, name => 'one.test' }, { id => 16668, name => 'two.test' } ] );
    my $hv   = node( node => $node );

    is_deeply [ sort $hv->guest_names ], [qw{one.test two.test}], 'every server in the project, whatever built it';
    ok $hv->domain_exists('one.test'), 'a guest that is there';
    ok !$hv->domain_exists('no.test'), 'and one that is not';

    is $hv->server('one.test')->{id}, 21995, 'a server is found by the domain name';

    my $twice = Test::FakeNode->new( servers => [ { id => 1, name => 'same.test' }, { id => 2, name => 'same.test' } ] );
    like exception { node( node => $twice )->server('same.test') }, qr/2 servers called 'same.test'/,
      'and two of a name is refused rather than guessed between, because the next thing done with the answer deletes it';
};

subtest 'the address a guest is reached at' => sub {
    my $node = Test::FakeNode->new(
        servers => [
            {
                id           => 1,
                name         => 'one.test',
                status       => 'started',
                ip_addresses => { ipv4 => [ { ip => '10.4.32.98' }, { ip => '10.4.32.49', is_primary => 1 } ], ipv6 => [] },
            },
        ],
    );

    is node( node => $node )->guest_ssh_ip('one.test'), '10.4.32.49', 'the primary address, which is the one the node itself shows';

    my $unprimary = Test::FakeNode->new( servers => [ { id => 1, name => 'one.test', status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.98' } ] } } ] );
    is node( node => $unprimary )->guest_ssh_ip('one.test'), '10.4.32.98', 'or the only one, where the node marked none of them';

    my $building = Test::FakeNode->new( servers => [ { id => 1, name => 'one.test', status => 'processing', ip_addresses => { ipv4 => [] } } ] );
    like exception { node( node => $building )->guest_ssh_ip('one.test') }, qr/no IPv4 address.*processing/s,
      'a guest with no address says what it is doing instead of handing back nothing';

    like exception { node()->guest_ssh_ip('gone.test') }, qr/no guest called 'gone.test'/, 'and one that is not there says that';
};

subtest 'snapshots belong to the server' => sub {
    my $node = Test::FakeNode->new(
        servers   => [ { id => 21995, name => 'one.test' } ],
        snapshots => { 21995 => [ { id => 7, name => 'before', created_at => '2026-01-01' }, { id => 9, name => 'after', created_at => '2026-06-01' } ] },
    );
    my $hv = node( node => $node );

    is_deeply [ $hv->snapshot_names('one.test') ], [qw{after before}], 'newest first';
    is $hv->snapshot_current_name('one.test'), 'after', 'and the newest is what passes for a current one';

    $hv->create_snapshot( 'one.test', 'now' );
    my ($made) = $node->calls_to('create_a_new_server_snapshot');
    is_deeply $made->[1], { id => 21995, name => 'now' }, 'taking one names the server and the snapshot';

    $hv->revert_snapshot( 'one.test', 'before' );
    my ($reverted) = $node->calls_to('revert_snapshot');
    is_deeply $reverted->[1], { id => 7 },
      "reverting names the snapshot's own id, since that is what the node's endpoint takes";

    like exception { $hv->revert_snapshot( 'one.test', 'never' ) }, qr/no snapshot called 'never'/, 'and one that does not exist is refused';
};

subtest 'building a guest' => sub {
    my $node = Test::FakeNode->new( plans => [ \%PLAN ] );
    my $hv   = node( node => $node, plan => 2375, location => 8, os => 28 );

    my $made = $hv->create_guest( name => 'new.test', user_data => "#cloud-config\n" );
    is $made->{id}, 24595, 'the server comes back, having been waited for';

    my ($asked) = $node->calls_to('create_a_new_project_server');
    is_deeply $asked->[1],
      {
        id                  => 34,
        name                => 'new.test',
        plan_id             => 2375,
        location_id         => 8,
        os_image_version_id => 28,
        user_data           => "#cloud-config\n",
      },
      "the project endpoint's own field names, which are not the node-wide endpoint's";

    like exception { node( node => Test::FakeNode->new( plans => [ \%PLAN ] ), plan => 2375, location => 8 )->create_guest( name => 'x.test' ) },
      qr/needs an os image version/, 'and one with no OS version configured says which key, and that a version is not an image';

    like exception { $hv->create_guest() }, qr/needs a name/, 'a guest with no name is refused';
};

subtest 'reinstalling one that is already there' => sub {
    my $node = Test::FakeNode->new(
        plans   => [ \%PLAN ],
        servers => [ { id => 21995, name => 'one.test', status => 'started', ip_addresses => { ipv4 => [ { ip => '10.4.32.49', is_primary => 1 } ] } } ],
    );
    my $hv = node( node => $node, plan => 2375, location => 8, os => 28 );

    $hv->reinstall_guest( 'one.test', user_data => "#cloud-config\nkey\n" );

    my ($asked) = $node->calls_to('reinstall_server');
    is_deeply $asked->[1], { id => 21995, os => 28, user_data => "#cloud-config\nkey\n" },
      "reinstall calls the same thing 'os' that create calls 'os_image_version_id', and the payload is why this is not a delete and rebuild";

    like exception { $hv->reinstall_guest('gone.test') }, qr/no guest called 'gone.test' to reinstall/, 'and there has to be one to reinstall';
};

subtest 'taking one away' => sub {
    my $node = Test::FakeNode->new( servers => [ { id => 21995, name => 'one.test' } ] );
    my $hv   = node( node => $node );

    ok $hv->annihilate_domain('one.test'), 'a guest that was there is deleted';
    my ($deleted) = $node->calls_to('delete_server');
    is_deeply $deleted->[1], { id => 21995 }, 'by its id';

    is $hv->annihilate_domain('one.test'), 0, 'and asking again is false rather than fatal, so a teardown can be run twice';

    my $staying = Test::FakeNode->new( servers => [ { id => 1, name => 'stuck.test' } ], keep => 1 );

    local $Trog::HV::SolusVM::DELETE_TIMEOUT = 0;
    like exception { node( node => $staying )->annihilate_domain('stuck.test') }, qr/still there 0s after being deleted/,
      'a delete the node accepted and did not do is said to be that, rather than waited on forever';
};

subtest 'what it has nothing to do about' => sub {
    my $hv = node();

    is $hv->prepare_host('/some/virtiofs'), 1, 'there is no machine to prepare';
    is $hv->release_seed('one.test'),       1, 'no seed drive to release -- the payload is a field on the server';
    is $hv->clear_guest('one.test'),        1, 'and nothing to clear, because a guest is reinstalled in place';
    is_deeply [ $hv->guest_volumes('one.test') ], [], 'a guest\'s disks go with it when it is deleted';
};

subtest 'what it refuses to pretend to' => sub {
    my $hv = node();

    like exception { $hv->cloudinit_iso }, qr/no cloudinit_iso: the node takes cloud-init as user_data/,
      'a libvirt noun says what this has instead';
    like exception { $hv->pool_path }, qr/no pool_path: there is no storage pool/,  'rather than an undef the caller carries somewhere else';
    like exception { $hv->lease_ip },  qr/no lease_ip: the node assigns addresses/, 'and the address table is the node\'s';
};

subtest 'preflight' => sub {
    my $node = Test::FakeNode->new( plans => [ \%PLAN ] );
    my $hv   = node( node => $node, plan => 2375, location => 8, os => 28 );

    is_deeply [ $hv->preflight_checks ],
      [qw{check_reachable check_solusvm_resources check_solusvm_quota check_rsync check_transfer_ip check_fetch_sources check_config}],
      'the checks are asked in an order where the credential comes first';

    my $reachable = $hv->check_reachable;
    ok $reachable->{ok}, 'a token that works is reachable';
    like $reachable->{what}, qr/you\@example\.test \(CLIENT\)/, 'and says who it is, and what it may do';

    my $resources = $hv->check_solusvm_resources;
    ok $resources->{ok}, 'the plan, location and OS version all being real is a pass';
    like $resources->{what}, qr/project 34 as c8\.d80\.r1024.*Debian 13/, 'said in the words somebody would recognise';

    my $wrong = node( node => Test::FakeNode->new( plans => [ \%PLAN ] ), plan => 2375, location => 8, os => 999 );
    my $bad   = $wrong->check_solusvm_resources;
    ok !$bad->{ok}, 'an OS version the node does not have is a failure';
    like $bad->{fix}, qr/28\s+Debian 13/, 'and the fix lists what it does have, since an id is not guessable';

    my $quota = $hv->check_solusvm_quota;
    ok $quota->{ok}, 'an account with no limit has room';
    like $quota->{what}, qr/no limit the node will tell us about/, 'and says that rather than inventing a number';

    my $full = node(
        node       => Test::FakeNode->new( plans => [ \%PLAN ], servers => [ { id => 1, name => 'a.test' }, { id => 2, name => 'b.test' } ] ),
        plan       => 2375,
        max_guests => 2,
    );
    ok !$full->check_solusvm_quota->{ok}, 'and one at its limit has not';
};

subtest 'provisioning' => sub {
    my $config = Config::Simple->new( syntax => 'ini' );
    $config->param( 'domain', 'new.test' );

    my $node = Test::FakeNode->new( plans => [ \%PLAN ] );
    my $hv   = node( node => $node, plan => 2375, location => 8, os => 28 );

    my $address = $hv->provision_guest( $config, { 'user-data' => "#cloud-config\n" } );
    is $address,                                              '10.4.32.97', 'a guest that was not there is built, and its address comes back';
    is scalar $node->calls_to('create_a_new_project_server'), 1,            'by asking for one';

    $address = $hv->provision_guest( $config, { 'user-data' => "#cloud-config\n" } );
    is scalar $node->calls_to('reinstall_server'),            1, 'a guest that is there is reinstalled rather than replaced';
    is scalar $node->calls_to('create_a_new_project_server'), 1, 'so the node is not asked for a second one';

    $hv->provision_guest( $config, { 'user-data' => "#cloud-config\n" }, reuse => 1 );
    is scalar $node->calls_to('reinstall_server'), 1, 'and reuse leaves the guest alone entirely';
};

subtest 'a dry run asks nothing of the node it does not have to' => sub {
    my $config = Config::Simple->new( syntax => 'ini' );
    $config->param( 'domain', 'new.test' );

    my $node = Test::FakeNode->new;
    my $hv   = node( node => $node );

    is $hv->would_provision($config), '(not built)', 'a guest that does not exist has no address to report';
    is scalar $node->calls_to('get_an_existing_server'), 0,
      'and it is not asked for one, which on a guest that is not there is an error rather than an answer';
};

done_testing;
