#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-ubuntu.t - the five files a guest first boots from

=head1 DESCRIPTION

These used to be built in perl, as data structures handed to C<YAML::XS::Dump>,
by the C<mongle_*> subs in F<bin/provision>.  They are templates now.

So the assertion that matters is that the documents did not change: each is
loaded back as YAML and compared against the structure the old code produced for
the same inputs, which is written out below.  Comparing the data rather than the
text is the point -- what cloud-init reads is the structure, and a template that
produced the same structure with different quoting is a template that works.

The inputs are chosen to break a template that writes YAML without quoting it: a
GECOS with an apostrophe, an ampersand and a colon in it, and a contact address
with an apostrophe.  Those are all things an operator may legitimately have, and
each of them ends a plain YAML scalar early.

=cut

use Test::More;
use Test::Deep;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use Test::MockModule qw{strict};
use YAML::XS();
use IPC::Run3();

use FindBin::libs;
use Provisioner::Utils();

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

# Loaded so that blessing into it below blesses into something real, and so
# Test::MockModule in strict mode has methods to find.  The backend rather than
# Trog::HV, because that is where the libvirt methods these mocks replace live,
# and Trog::HV requires it lazily.
use Trog::HV::Libvirt();
use Trog::HV::OpenStack();    ## no critic (ProhibitUnusedImports)
use Provisioner::Cookbook();

my $DOMAIN    = 'vm.test.test';
my $GECOS     = q{Sean O'Brien & Co: boss};
my $EMAIL     = q{o'brien&sons@test.test};
my $RESOLVERS = [ '192.0.2.253', '8.8.8.8' ];

# The guest's own configuration, as bin/new_config hands it over.
sub settings (%overrides) {
    return (
        domain        => $DOMAIN,
        ips           => ['192.0.2.10'],
        gateway       => '192.0.2.254',
        resolvers     => $RESOLVERS,
        contact_email => $EMAIL,
        admin_user    => 'admin',
        users         => [
            {
                name          => 'admin', gecos => $GECOS, shell => '/bin/bash',
                sudo          => 'ALL=(ALL) NOPASSWD:ALL',
                ssh_import_id => ['gh:someone'],
            }
        ],
        packages      => [qw{nginx mariadb-server}],
        transfer_ip   => '192.168.122.251',
        transfer_port => 22,
        transfer_user => 'transfer',

        # What bin/new_config hands over as the ip pool's assignments, which is
        # how a mirror named by bare domain gets resolved to an address.
        ipmap => { 'm.test.test' => '192.0.2.9' },
        %overrides,
    );
}

# Generate the five, and hand back the directory they landed in.  hv is what
# the block of the hypervisor names, by default a lease on virbr0 and an address
# on br0.
sub generated {
    my (%extra) = @_;

    # virbr_ip is the only thing here that would talk to libvirt.  The object
    # itself is handed over rather than intercepted: redefining new() worked
    # only while the recipe constructed its own.
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( virbr_ip => sub { return '192.168.122.1' } );
    my $hv = bless { %{ delete $extra{hv} // { dhcp_nics => 'virbr0', static_nics => 'br0' } } }, 'Trog::HV::Libvirt';

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load('ubuntu')->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        hv            => $hv,
    );

    my @written = $recipe->generate_files( $dir, settings(%extra) );
    return ( $dir, \@written );
}

sub loaded {
    my ( $dir, $file ) = @_;
    return YAML::XS::Load( File::Slurper::read_binary("$dir/$file") );
}

# bin/new_config hands the admin user the keys out of admin_authorized_keys, and
# enrich adds the guest's own to the same list.  Whichever of the two went in
# first, losing the other is silent: the operator locked out of a guest that
# built perfectly well, or a guest this machine cannot get back into to run the
# makefile.
subtest 'the domain key joins the administrator keys rather than replacing them' => sub {
    my $theirs = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAoperatorskey operator';

    my ( $dir, undef ) = generated(
        users => [
            {
                name                => 'admin', gecos => $GECOS, shell => '/bin/bash',
                sudo                => 'ALL=(ALL) NOPASSWD:ALL',
                ssh_authorized_keys => [$theirs],
            }
        ]
    );

    my ($admin) = grep { $_->{name} eq 'admin' } @{ loaded( $dir, 'user-data' )->{users} };
    my @keys = @{ $admin->{ssh_authorized_keys} // [] };

    ok( ( grep { $_ eq $theirs } @keys ), 'the keys the configuration supplied are still there' )
      or diag explain \@keys;
    ok( ( grep { m/\Assh-rsa[ ]/ } @keys ), 'and the domain key was added beside them' )
      or diag explain \@keys;
    is( scalar @keys, 2, 'both, and nothing invented' );
};

subtest 'a guest a service made has no interfaces of ours to match on' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    Trog::HV->forget();
    my $cloud = Trog::HV->new( cloud => 'testcloud' );

    my $recipe = Provisioner::Cookbook->load('ubuntu')->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        hv            => $cloud,
    );

    # enrich asks the hypervisor what a guest will call its interfaces and what
    # MACs it will have.  A cloud refuses both -- it assigned the MAC and the
    # image chose the name -- so the question has to not be asked rather than
    # answered wrongly.
    my @written = $recipe->generate_files( $dir, settings( ips => [], gateway => undef ) );
    is scalar @written, 4, 'the four files are still written';

    is_deeply loaded( $dir, 'network-config' ), { network => { config => 'disabled' } },
      'and the network is left to the platform, which is what a cloud image expects';

    Trog::HV->forget();
};

subtest 'the four files are written, and the three YAML ones are YAML' => sub {
    my ( $dir, $written ) = generated();

    is_deeply(
        [ sort @$written ],
        [qw{meta-data network-config setup.sh user-data}],
        'every file a guest boots from is generated'
    );

    foreach my $file (qw{user-data network-config meta-data}) {
        is( exception { loaded( $dir, $file ) }, undef, "$file parses as YAML" );
    }

    my $setup = File::Slurper::read_text("$dir/setup.sh");
    unlike( $setup, qr/\[%/, 'the setup script has nothing of the template left in it' );
    like( $setup, qr/\Q$DOMAIN\E/, 'and knows which domain it is fetching for' );

    # It fetches from whoever wrote the payload, which is this machine, through
    # the module that bin/new_config writes for the domain.
    # t/new_config-rsyncd.t has what that module serves.
    cmp_ok( index( $setup, "transfer\\\@192.168.122.251::payload.$DOMAIN/data.tar.gz" ), '>=', 0, 'from the machine holding the payload, through the module of the domain' ) or diag $setup;
};

# bin/provision places the secrets over ssh while cloud-init runs, so setup.sh
# has to wait for them.  The wait is run here under sh, as at(1) would run it,
# with its limit cut to a few seconds and its logs moved into a temporary dir.
subtest 'setup.sh waits for the secrets of a domain that has any' => sub {
    my $tmp    = tempdir( CLEANUP => 1 );
    my $marker = "$tmp/guest-secrets-marker";

    my ( $plain_dir, undef ) = generated();
    unlike( File::Slurper::read_text("$plain_dir/setup.sh"), qr/waited=/, 'a domain with no secrets starts make at once' );

    my ( $dir, undef ) = generated( secrets_marker => $marker );
    my $setup = File::Slurper::read_text("$dir/setup.sh");
    my ($wait) = $setup =~ m/^(waited=0\n.*?^rm[ ]-f[ ]\Q$marker\E\n)/ms;
    ok( defined $wait,                                       'one with secrets waits for the marker, and then removes it' ) or return diag $setup;
    ok( index( $setup, $wait ) < index( $setup, 'make -j' ), 'before make' );

    $wait =~ s/\b1800\b/3/;
    $wait =~ s{/var/log/}{$tmp/}g;
    my $run = sub {
        my ($before) = @_;
        my $out = q{};
        IPC::Run3::run3( [ 'sh', '-c', "$before\n$wait" ], \undef, \$out, \$out );
        return ( $? >> 8, $out );
    };

    File::Slurper::Temp::write_text( $marker, "placed\n" );
    is( ( $run->(q{}) )[0], 0, 'a marker already there lets it go on' );
    ok( !-e $marker, 'and it is removed, so the next build waits for its own' );

    is( ( $run->("( sleep 1; touch $marker ) &") )[0], 0, 'a marker that comes a second later lets it go on then' );
    ok( !-e $marker, 'and that one is removed too' );

    is( ( $run->(q{}) )[0],                                    1,     'no marker at all stops it at the limit' );
    is( File::Slurper::read_text("$tmp/$DOMAIN.setup.status"), "1\n", 'recording a failed build, which bin/provision reads' );
    like( File::Slurper::read_text("$tmp/$DOMAIN.setup.log"), qr/\Q$marker\E/, 'with a log that names the marker it waited for' );
};

# apt hands an option to dpkg only when it is spelled Dpkg::Options::=.  With one
# pair of colons apt takes it and dpkg never sees it, so a changed conffile
# stops the upgrade with exit 100, which a guest showed.
subtest 'the packager commands hand their options to dpkg' => sub {
    my $ubuntu = Provisioner::Cookbook->load('ubuntu');
    foreach my $method (qw{packager_invocation packager_up_invocation}) {
        my $cmd     = $ubuntu->$method();
        my @options = $cmd =~ m/-o[ ](Dpkg::Options\S*)/g;
        like( $cmd, qr/--force-confold/, "$method keeps the configuration a guest changed" );
        is_deeply( [ grep { !m/\ADpkg::Options::=/ } @options ], [], "and every option of $method reaches dpkg" ) or diag $cmd;
    }
};

# The documents a guest with no mirror configured gets, written out rather than
# derived so that this compares against something which is not the code under
# test.  Everything but the apt block is what has always been produced; the apt
# block is the no-op default, and the mirror cases are further down.
subtest 'the documents a guest with no mirror is built from' => sub {
    my ( $dir, undef ) = generated();

    my $pubkey = File::Slurper::read_text("$dir/key.rsa.pub");
    chomp $pubkey;

    cmp_deeply(
        loaded( $dir, 'meta-data' ),
        { 'instance-id' => $DOMAIN, 'local-hostname' => $DOMAIN },
        'meta-data'
    );

    cmp_deeply(
        loaded( $dir, 'network-config' ),
        {
            network => {
                version   => 2,
                ethernets => {
                    ens4 => {
                        match       => { macaddress => Trog::HV::Libvirt->guest_mac( $DOMAIN, 1 ) },
                        'set-name'  => 'ens4',
                        addresses   => ['192.0.2.10/24'],
                        routes      => [ { to => 'default', via => '192.0.2.254' } ],
                        nameservers => { search => [$DOMAIN], addresses => $RESOLVERS },
                    },

                    # The MAC as the client identifier, so that a rebuilt guest,
                    # which has a new machine-id and so a new DUID, asks dnsmasq
                    # as the same client and gets back the lease it had.
                    ens3 => {
                        match             => { macaddress => Trog::HV::Libvirt->guest_mac( $DOMAIN, 0 ) },
                        'set-name'        => 'ens3',
                        dhcp4             => bool(1),
                        'dhcp-identifier' => 'mac',
                    },
                },
            }
        },
        'network-config'
    );

    my ( $prefixed, undef ) = generated( ips => [ '192.0.2.10', '198.51.100.7/28' ] );
    cmp_deeply(
        loaded( $prefixed, 'network-config' )->{network}{ethernets}{ens4}{addresses},
        [ '192.0.2.10/24', '198.51.100.7/28' ],
        'an address with no prefix gets /24, as cloud-init gave one in the version 1 format, and a prefix that is given is kept'
    );

    my $user_data = loaded( $dir, 'user-data' );

    # The one field that is not identical, and the only one: the apt conf blob
    # used to be written with a leading newline and no trailing one, both of
    # which came from how the perl string was quoted rather than from anything
    # apt cares about.  Compared without them so the rest can be compared
    # exactly.
    my $apt_conf = delete $user_data->{apt}{conf};
    $apt_conf =~ s/\A\s+|\s+\z//g;
    is(
        $apt_conf, <<'CONF' =~ s/\A\s+|\s+\z//gr,
Acquire {
    Retries "12";
    Force-IPv4: true;
}
APT {
    Get {
        Assume-Yes "true";
        Fix-Broken "true";
    }
}
DPkg {
    Lock {
        Timeout "600";
    }
}
CONF
        'the apt configuration, which apt reads whitespace-insensitively, with the wait for the dpkg lock that make -j needs'
    );

    # With no mirror there is nothing to redirect apt at, so the whole apt key
    # is now just that conf.  AllowInsecureRepositories went with the mirror:
    # it was there because the one on the hypervisor was unsigned.
    is_deeply( $user_data->{apt}, {}, 'and nothing else under apt, there being no mirror to point at' );
    delete $user_data->{apt};

    cmp_deeply(
        $user_data,
        {
            fqdn             => $DOMAIN,
            manage_etc_hosts => 'localhost',
            final_message    => 'Boot configuration complete.',
            package_update   => bool(1),
            package_upgrade  => bool(1),

            # atd is how the makefile gets started, make is what runs it, bash is
            # the shell it runs recipe lines with, and
            # something has to take mail -- none of which any recipe asked for.
            packages => [qw{nginx mariadb-server sendmail at bash make}],

            # The guest's own key, authorized on the admin rather than on root.
            users => [
                {
                    name          => 'admin',
                    gecos         => $GECOS,
                    shell         => '/bin/bash',
                    sudo          => 'ALL=(ALL) NOPASSWD:ALL',
                    ssh_import_id => ['gh:someone'],

                    # YAML folds a long plain scalar across lines and unfolds it
                    # to a space, which is where the space in a public key
                    # already is.  Master did the same, being the same dumper.
                    ssh_authorized_keys => [ re(qr/\Assh-rsa[ ]\S+[ ]\S+\z/) ],
                }
            ],

            write_files => [

                # Any private key container ssh will load: Net::SSH::Perl::Key
                # writes RSA as PKCS1 PEM where ssh-keygen wrote an OpenSSH one.
                { path => '/root/.ssh/id_rsa',     owner => 'root:root', permissions => '0600', defer => bool(1), content => re(qr/\A-----BEGIN[ ][[:upper:]\d ]*PRIVATE[ ]KEY-----/) },
                { path => '/root/.ssh/id_rsa.pub', owner => 'root:root', permissions => '0600', defer => bool(1), content => re(qr/\Assh-rsa[ ]/) },
                { path => '/root/setup.sh',        owner => 'root:root', permissions => '0775', defer => bool(1), content => re(qr/cloud-init[ ]status[ ]--wait/) },

                # No mirrorlist, and so nothing left that cloud-init has to write
                # before it installs anything: it was the only defer: false entry.
            ],

            # The override of var.conf, which the subtest of /var/log below
            # runs, and the directory above the home of the admin.
            bootcmd => [ ignore(), 'mkdir -p /home' ],

            # The newline in the middle of the first of these is as it has always
            # been, and is why runcmd is built as a list rather than written out
            # in the template: a YAML sequence item cannot carry one inline.
            runcmd => [ qq{echo "root:$EMAIL\n" > /etc/aliases }, q{echo 'bash /root/setup.sh' | at now} ],
        },
        'user-data'
    );
};

subtest 'a MAC with no hex letters in it survives the trip to PyYAML' => sub {

    # guest_mac takes the first six hex digits of a SHA of the domain name, so
    # roughly one domain in twenty-six gets a MAC whose octets are all decimal
    # digits.  YAML 1.1 reads colon-separated numbers as a base-60 integer and
    # PyYAML still does; the libyaml under YAML::XS does not, so it sees a
    # string and writes it bare.  cloud-init then calls .lower() on an int, the
    # network stage dies, and the guest hangs on systemd-networkd-wait-online
    # having never written a netplan or asked for a lease.
    #
    # Asserted on the rendered text rather than by loading it, because the whole
    # defect is that the parser available here disagrees with the one on the
    # guest about what that text means.
    my ( $dir, undef ) = generated( nat_mac => '52:54:00:11:44:22', bridge_mac => '52:54:00:f8:83:fc' );
    my $config = File::Slurper::read_text("$dir/network-config");

    like( $config, qr/^\s+macaddress:[ ]'52:54:00:11:44:22'$/m, 'an all-decimal MAC is quoted' );
    like( $config, qr/^\s+macaddress:[ ]52:54:00:f8:83:fc$/m,   'and one with hex letters is left alone' );

    my %formatters = 'Provisioner::Recipe::ubuntu'->formatters();
    my $yaml       = sub ($value) { return q{} . $formatters{yaml}->($value) };

    # 59 is the last sexagesimal digit, so the quoting stops at exactly the
    # point PyYAML stops misreading.
    is( $yaml->('52:54:00:11:59:22'), q{'52:54:00:11:59:22'}, '59 is still a base-60 digit' );
    is( $yaml->('52:54:00:11:60:22'), '52:54:00:11:60:22',    'and 60 is not, so it needs no quoting' );

    # It is a scalar rule, and must not reach into a structure being dumped.
    is( $yaml->( [qw{a b}] ), "- a\n- b", 'a list is dumped as it always was' );
};

subtest 'a bin that another guest routes to gets a route through that guest, once' => sub {
    my %pool = (
        ip_pool => {
            cidr => '192.0.2.0/24',
            bins => { vpnclients => { cidr => '10.8.0.128/25', addresses => '10.9.0.7', via => 'vpn.test.test' } },
        },
        ipmap => { 'vpn.test.test' => '192.0.2.20' },
    );

    my $routes = sub ($dir) { return loaded( $dir, 'network-config' )->{network}{ethernets}{ens4}{routes} };
    my ( $dir, undef ) = generated( %pool, ips => [ '192.0.2.10', '192.0.2.11' ] );
    cmp_deeply(
        $routes->($dir),
        [
            { to => 'default',       via => '192.0.2.254' },
            { to => '10.8.0.128/25', via => '192.0.2.20' },
            { to => '10.9.0.7/32',   via => '192.0.2.20' },
        ],
        'each network of the bin goes through the address of its via, once for the interface, because netplan refuses a route twice'
    ) or diag explain $routes->($dir);

    ( $dir, undef ) = generated( %pool, domain => 'vpn.test.test' );
    cmp_deeply( $routes->($dir), [ { to => 'default', via => '192.0.2.254' } ], 'and the guest that it names routes to the bin itself' );

    ( $dir, undef ) = generated( %pool, ipmap => {} );
    cmp_deeply( $routes->($dir), [ { to => 'default', via => '192.0.2.254' } ], 'as does a guest that cannot know where its via is' );
};

# What master wrote for this guest from a block with virbr0 and br0, before
# dhcp_nics and static_nics, byte for byte.  A block with one bridge in each
# list gives its guests exactly this.
my $NETWORK_CONFIG_BEFORE_NICS = <<'YAML';
---
network:
  version: 2
  ethernets:
    ens4:
      match:
        macaddress: 52:54:00:e3:de:7f
      set-name: ens4
      nameservers:
        search:
          - vm.test.test
        addresses:
          - 192.0.2.253
          - 8.8.8.8
      addresses:
        - 192.0.2.10/24
      routes:
        - to: default
          via: 192.0.2.254
    ens3:
      match:
        macaddress: 52:54:00:5f:7b:e3
      set-name: ens3
      dhcp4: true
      dhcp-identifier: mac
YAML

subtest 'one bridge in each list gives the network configuration that it always gave' => sub {
    my ( $dir, undef ) = generated();
    is( File::Slurper::read_text("$dir/network-config"), $NETWORK_CONFIG_BEFORE_NICS, 'the same text as before' );
};

subtest 'each adapter gets its part of the network configuration' => sub {
    my $mac = sub ($index) { Trog::HV::Libvirt->guest_mac( $DOMAIN, $index ) };

    my ( $dir, undef ) = generated( hv => { dhcp_nics => 'virbr0 virbr2', static_nics => 'virbr1 br0' }, nic_ips => { br0 => '192.0.2.70' } );
    my $ethernets = loaded( $dir, 'network-config' )->{network}{ethernets};

    cmp_deeply( [ sort keys %$ethernets ], [qw{ens3 ens4 ens5 ens6}],                                                                             'one entry for each adapter, named after its slot' );
    cmp_deeply( $ethernets->{ens3},        superhashof( { match => { macaddress => $mac->(0) }, dhcp4 => bool(1), 'dhcp-identifier' => 'mac' } ), 'the lease on the first of dhcp_nics' );
    ok( !exists $ethernets->{ens3}{'dhcp4-overrides'}, 'with its routes' );
    cmp_deeply(
        $ethernets->{ens4},
        superhashof( { match => { macaddress => $mac->(1) }, dhcp4 => bool(1), 'dhcp4-overrides' => { 'use-routes' => bool(0) }, optional => bool(1) } ),
        'a lease on the other, and no route from it'
    );
    cmp_deeply(
        $ethernets->{ens5},
        superhashof( { match => { macaddress => $mac->(2) }, addresses => ['192.0.2.10/24'], routes => [ { to => 'default', via => '192.0.2.254' } ] } ),
        'the address of the guest and the default route on the first of static_nics'
    );
    cmp_deeply(
        $ethernets->{ens6},
        { match => { macaddress => $mac->(3) }, 'set-name' => 'ens6', addresses => ['192.0.2.70/24'], optional => bool(1) },
        'and the address of the other static adapter, with no route, so the guest routes through the first'
    );
};

# A guest whose pools are not /24 networks: its address on a /26, and another
# on a /27.  bin/new_config writes each address with the prefix of the network
# of its bridge, and the network configuration keeps it.
my $NETWORK_CONFIG_OF_PREFIXES = <<'YAML';
---
network:
  version: 2
  ethernets:
    ens4:
      match:
        macaddress: 52:54:00:e3:de:7f
      set-name: ens4
      nameservers:
        search:
          - vm.test.test
        addresses:
          - 192.0.2.253
          - 8.8.8.8
      addresses:
        - 10.0.0.70/26
      routes:
        - to: default
          via: 10.0.0.1
    ens5:
      match:
        macaddress: MAC2
      set-name: ens5
      addresses:
        - 192.0.2.70/27
      optional: true
    ens3:
      match:
        macaddress: 52:54:00:5f:7b:e3
      set-name: ens3
      dhcp4: true
      dhcp-identifier: mac
YAML

subtest 'a static address keeps the prefix of the network of its bridge' => sub {
    my ( $dir, undef ) = generated( hv => { dhcp_nics => 'virbr0', static_nics => 'virbr1 br0' }, ips => ['10.0.0.70/26'], gateway => '10.0.0.1', nic_ips => { br0 => '192.0.2.70/27' } );
    my $mac2 = Trog::HV::Libvirt->guest_mac( $DOMAIN, 2 );
    is( File::Slurper::read_text("$dir/network-config"), $NETWORK_CONFIG_OF_PREFIXES =~ s/MAC2/$mac2/r, 'each address with its own prefix, and no /24' );
};

subtest 'a guest with no static adapter takes its nameservers on its lease' => sub {
    my ( $dir, undef ) = generated( hv => { dhcp_nics => 'virbr0' }, ips => [], gateway => undef );
    my $ethernets = loaded( $dir, 'network-config' )->{network}{ethernets};

    cmp_deeply( [ keys %$ethernets ],                       ['ens3'],   'one adapter' );
    cmp_deeply( $ethernets->{ens3}{nameservers}{addresses}, $RESOLVERS, 'and the resolvers of the block are on it' );

    like( exception { generated( hv => { dhcp_nics => 'virbr0' } ) }, qr/hypervisor[ ]names[ ]no[ ]static_nics/, 'while an address with no static adapter to put it on is refused' );
};

subtest 'a guest with no addresses takes a lease on the NAT side, and leaves the bridge alone' => sub {
    foreach my $gateway ( undef, '192.0.2.254' ) {
        my $with = defined $gateway ? 'with the gateway of the fleet' : 'with no gateway';
        my ( $dir, undef ) = generated( ips => [], gateway => $gateway );

        my $config = loaded( $dir, 'network-config' )->{network}{ethernets};
        ok( !exists $config->{ens4}{addresses}, "the bridge asks for no address, $with" );
        ok( !exists $config->{ens4}{routes},    'and claims no gateway, which it could not reach' );
        cmp_deeply( $config->{ens3}, superhashof( { dhcp4 => bool(1), 'dhcp-identifier' => 'mac' } ), 'and the NAT side takes its lease, as it always does' );
    }
};

subtest 'a guest with addresses and no gateway is refused' => sub {
    like(
        exception { generated( gateway => undef ) },
        qr/MUST[ ]SET[ ]gateway/,
        'rather than written out with a static subnet routing nowhere'
    );

    like(
        exception { generated( contact_email => undef ) },
        qr/MUST[ ]SET[ ]contact_email/,
        'and root mail has to have somewhere to go'
    );
};

subtest 'the key a domain already has is kept, on a real run and a dry one' => sub {

    # virbr_ip is the only thing here that would talk to libvirt.  The object
    # itself is handed over rather than intercepted: redefining new() worked
    # only while the recipe constructed its own.
    my $mock = Test::MockModule->new('Trog::HV::Libvirt');
    $mock->redefine( virbr_ip => sub { return '192.168.122.1' } );
    my $hv = bless { dhcp_nics => 'virbr0', static_nics => 'br0' }, 'Trog::HV::Libvirt';

    my $dir   = tempdir( CLEANUP => 1 );
    my $build = sub {
        my (%extra) = @_;
        Provisioner::Cookbook->load('ubuntu')->new(
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => $dir,
            hv            => $hv,
        )->generate_files( $dir, settings(%extra) );
        return File::Slurper::read_text("$dir/key.rsa");
    };

    my $first = $build->();

    # A private key ssh will load, rather than one particular container:
    # Provisioner::Utils::write_ssh_keypair goes through Net::SSH::Perl::Key,
    # which writes RSA as PKCS1 PEM where ssh-keygen wrote an OpenSSH one.  Both
    # load; what matters is that the halves belong together, which is what
    # ssh_pubkey_from_private answers.
    like( $first, qr/\A-----BEGIN[ ][[:upper:]\d ]*PRIVATE[ ]KEY-----/, 'a domain with no key gets one' );
    is(
        Provisioner::Utils::ssh_pubkey_from_private("$dir/key.rsa"),
        ( File::Slurper::read_text("$dir/key.rsa.pub") =~ s/[ ][^ ]*\n?\z//r ),
        'and its public half is the one written beside it'
    );

    # The guest that is up has the public half of this, so a run that is meant
    # to change nothing must not replace the private half.
    is( $build->( dryrun => 1 ), $first, 'a dry run leaves the one a live guest is using alone' );

    # Nor does a real one: a guest is rebuilt around the key it is seeded with,
    # so replacing one here leaves whoever already holds it unable to get back
    # in -- and the store is holding this one.
    is( $build->(), $first, 'and a real run keeps it, since the store is holding that key' );
};

subtest 'release_version: the pinned release, as the image catalogs name it' => sub {
    my $recipe = Provisioner::Cookbook->load('ubuntu');
    is( $recipe->release,         'noble',  'noble is pinned' );
    is( $recipe->release_version, '24.04',  'which a catalog calls 24.04' );
    is( $recipe->distribution,    'ubuntu', 'of ubuntu' );

    my $pin = Test::MockModule->new('Provisioner::Recipe::ubuntu');
    $pin->redefine( release => sub { 'bogus' } );
    like( exception { $recipe->release_version }, qr/version[ ]of[ ]the[ ]release[ ]'bogus'/, 'a release with no version recorded is refused, not guessed at' );
};

# A domain names its release in _global, so that the fleet can move one domain
# at a time.
subtest 'a release that a domain names' => sub {
    my $recipe = Provisioner::Cookbook->load('ubuntu');

    is( $recipe->release_version('resolute'), '26.04',                        'its version, for a catalog' );
    is( $recipe->base_image('resolute'),      $recipe->image_for('resolute'), 'and its image, for libvirt' );
    isnt( $recipe->base_image('resolute'), $recipe->base_image, 'which is not the image of the pinned release' );

    is( $recipe->release_of( release => 'resolute' ), 'resolute', 'release_of takes the release that _global names' );
    is( $recipe->release_of(),                        'noble',    'and the pinned one when it names none' );
    like( exception { $recipe->release_of( release => 'bogus' ) }, qr/version[ ]of[ ]the[ ]release[ ]'bogus'/, 'and refuses one it does not know' );

    my %schema = $recipe->args;
    is( $schema{properties}{release}{default}, $recipe->release, 'the schema defaults it to the pinned release' );
    ok( ( grep { $_ eq 'resolute' } @{ $schema{properties}{release}{enum} } ), 'and takes each release whose version it knows' );
    ok( !( grep { $_ eq 'bogus' } @{ $schema{properties}{release}{enum} } ),   'and nothing else' );
};

subtest 'which release is current is read, not inferred' => sub {
    my $recipe = Provisioner::Cookbook->load('ubuntu');

    is( $recipe->base_image, $recipe->image_for( $recipe->release ), 'the image guests are built on is the pinned release' );
    like( $recipe->base_image, qr{\Ahttps://cloud-images\.ubuntu\.com/}, 'from the cloud image archive' );

    my $http = Test::MockModule->new('HTTP::Tiny');

    # meta-release-lts lists the next LTS before it ships, marked unsupported.
    # Taking the highest version, or simply the last Dist:, picks that one --
    # which would have every guest built on a release that does not exist yet.
    $http->redefine(
        get => sub {
            return {
                success => 1,
                content => <<'META',
Dist: jammy
Version: 22.04.5 LTS
Supported: 1

Dist: noble
Version: 24.04.4 LTS
Supported: 1

Dist: resolute
Version: 26.04.1 LTS
Supported: 0
META
            };
        }
    );
    is( $recipe->current_release, 'noble',                     'the last supported entry, not the last entry' );
    is( $recipe->current_image,   $recipe->image_for('noble'), 'and the image that goes with it' );

    # A mirror that will not answer is not something to guess past.
    $http->redefine( get => sub { return { success => 0, status => 599 } } );
    is( $recipe->current_release, undef, 'a fetch that failed says nothing' );
    is( $recipe->current_image,   undef, 'rather than an image nobody asked for' );
};

# --- What a configured mirror does ------------------------------------------
#
# The byte-for-byte mirrorlist assertion lives here rather than in the default
# case, because this is the case it describes.  The tabs are the format: apt
# mirror+file is tab separated, and an editor that helpfully converts them
# breaks it silently.
subtest 'a mirror named as a URL is used as written' => sub {
    my ( $dir, undef ) = generated( mirror => 'http://m.test.test/ubuntu' );
    my $user_data = loaded( $dir, 'user-data' );

    cmp_deeply(
        $user_data->{apt}{primary},
        [ { arches => ['default'], uri => 'mirror+file:/etc/apt/mirrorlist' } ],
        'apt is redirected at the mirrorlist'
    );
    cmp_deeply( $user_data->{apt}{security}, $user_data->{apt}{primary}, 'for security too' );
    like( $user_data->{apt}{conf}, qr/AllowInsecureRepositories:[ ]true;/, 'and unverified repositories are allowed, as they have always been with a mirror' );

    my ($mirrorlist) = grep { $_->{path} eq '/etc/apt/mirrorlist' } @{ $user_data->{write_files} };
    ok( $mirrorlist, 'the mirrorlist is written' ) or return;

    is(
        $mirrorlist->{content},
        "http://m.test.test/ubuntu\tpriority:1\nhttp://archive.ubuntu.com/ubuntu\tpriority:2\nhttp://security.ubuntu.com/ubuntu\tpriority:3\n",
        'the mirror first and the archive behind it, tab separated'
    );

    # apt needs this before the packages above it are installed, which is what
    # every other write_files entry does not need.
    cmp_deeply( $mirrorlist->{defer}, bool(0), 'and written before cloud-init installs anything' );
};

subtest 'a bare name is resolved out of the ip pool' => sub {

    # A guest runs cloud-init before it has a resolver, so a name is no use to
    # it and the address has to be baked in.
    my ( $dir, undef ) = generated( mirror => 'm.test.test' );
    my ($mirrorlist) = grep { $_->{path} eq '/etc/apt/mirrorlist' } @{ loaded( $dir, 'user-data' )->{write_files} };

    like( $mirrorlist->{content}, qr{\Ahttp://192\.0\.2\.9/ubuntu\t}, 'the address out of the pool, with the distribution path on it' );
};

subtest 'a name nothing has an address for is refused' => sub {
    like(
        exception { generated( mirror => 'nowhere.test.test' ) },
        qr/named[ ]as[ ]a[ ]URL[ ]instead/,
        'saying to use a URL, rather than writing http:/// into the guest and failing at first boot'
    );
};

subtest 'a mirror is not built out of itself' => sub {

    # The natural way to configure this is one line in _base's _global, which
    # necessarily includes the mirror host -- and on the build that makes it,
    # there is nothing there to fetch from yet.
    my ( $dir, undef ) = generated( mirror => $DOMAIN );
    my $user_data = loaded( $dir, 'user-data' );

    ok( !exists $user_data->{apt}{primary},                                               'the guest that is the mirror falls back to the archive' );
    ok( !( grep { $_->{path} eq '/etc/apt/mirrorlist' } @{ $user_data->{write_files} } ), 'and gets no mirrorlist' );
};

subtest 'a mirror whose indices are signed can be verified' => sub {

    # One built by the aptmirror recipe is a verbatim copy of the archive, so
    # apt verifies the distribution signature and never has to trust the host.
    my ( $dir, undef ) = generated( mirror => 'http://m.test.test/ubuntu', mirror_insecure => 0 );

    unlike( loaded( $dir, 'user-data' )->{apt}{conf}, qr/AllowInsecureRepositories/, 'so the allowance can be turned off' );
};

# cloud-init writes the archives before it installs, and answers the questions
# the packages ask.  A file that is deferred, or an answer that arrives after
# the install, is a package that does not install or a prompt that nobody sees.
# The files are whatever the packager of the distribution makes of what the
# recipes named, so it stands in here.
subtest 'the vendor archives and their answers are there before the packages' => sub {
    my @apt_files = (
        { path => '/etc/apt/keyrings/vendor.asc',           permissions => '0644', content => "-----BEGIN PGP PUBLIC KEY BLOCK-----\nbogus\n" },
        { path => '/etc/apt/keyrings/binary.gpg',           permissions => '0644', content => "mQ==\n", encoding => 'b64' },
        { path => '/etc/apt/sources.list.d/vendor.sources', permissions => '0644', content => "Types: deb\nURIs: https://apt.vendor.test\n" },
    );
    my @answers = ( 'vendor-pkg vendor/name string it: is quoted', 'vendor-pkg vendor/stats boolean false' );

    my %asked;
    my $packager = Test::MockModule->new('Provisioner::Packager::Deb');
    $packager->redefine( first_boot_files => sub { my ( undef, %args ) = @_; %asked = %args; return @apt_files } );

    my @sources = ( { name => 'vendor' } );
    my ( $dir, undef ) = generated( package_sources => \@sources, package_conflicts => ['apache2'], package_answers => [ @answers, $answers[0] ] );

    is_deeply( \%asked, { domain => $DOMAIN, sources => \@sources, conflicts => ['apache2'] }, 'the recipe asks its packager, with what the recipes named' );
    my $user_data = loaded( $dir, 'user-data' );
    my %written   = map { $_->{path} => $_ } @{ $user_data->{write_files} };

    foreach my $file (@apt_files) {
        my $got = $written{ $file->{path} } // {};
        is( $got->{content}, $file->{content}, "$file->{path} is written as given" );
        ok( !$got->{defer}, 'and before the install, not after it' );
    }
    is( $written{'/etc/apt/keyrings/binary.gpg'}{encoding}, 'b64', 'a binary key says it is base64, so cloud-init decodes it' );
    ok( !exists $written{'/etc/apt/keyrings/vendor.asc'}{encoding}, 'and a text one says nothing' );

    is( $user_data->{apt}{debconf_selections}{provisioner}, join( q{}, map { "$_\n" } @answers ), 'the answers go to apt once each, one per line, colon and all' );
    is( scalar @{ $user_data->{bootcmd} // [] },            2,                                    'and with no cache, only the override of var.conf and the home of the admin run at boot' );
};

subtest 'first boot installs through the fetch cache' => sub {
    my $script = "#!/bin/bash\necho 'the script'\n";
    my $cert   = "-----BEGIN CERTIFICATE-----\nbogus\n-----END CERTIFICATE-----";
    my ( $dir, undef ) = generated( fetch_cache => { address => '192.0.2.50', authority => $cert, hosts => [qw{apt.one.test apt.two.test}], script => $script } );
    my $user_data = loaded( $dir, 'user-data' );

    is( scalar @{ $user_data->{bootcmd} // [] }, 3, 'one command at boot after the override of var.conf, which runs before the packages install' );
    my $cmd = $user_data->{bootcmd}[1] // q{};

    my @lines = split m/\n/, $cmd;
    is( $lines[0], "if [ ! -e /etc/provisioner/state/$DOMAIN/state ]; then", 'only until the makefile of the domain has begun, so a reboot leaves the hosts alone' );
    like( $cmd, qr{<<'TROG_FETCH_VIA_CACHE'\n\Q$script\ETROG_FETCH_VIA_CACHE\n}, 'the script, whole, in a heredoc that the shell does not expand' );
    like( $cmd, qr{<<'TROG_FETCHCACHE_CA'\n\Q$cert\E\nTROG_FETCHCACHE_CA\n},     'the authority, with the newline that a heredoc needs' );
    is( $lines[-2], 'bash /run/trog-fetch_via_cache on 192.0.2.50 /run/trog-fetchcache-ca.crt apt.one.test apt.two.test', 'and it runs, for every host' );
};

# The first command at boot runs here in sh, as cloud-init runs it, with two
# directories of the test in place of /usr/lib/tmpfiles.d and /etc/tmpfiles.d.
subtest 'first boot makes the directory above the home of the admin, before cloud-init makes the account' => sub {
    my ($runs) = generated( install_dir => '/bogus/hosts', user => 'admin' );
    is( loaded( $runs, 'user-data' )->{bootcmd}[-1], 'mkdir -p /bogus/hosts', 'install_dir, when the admin runs the domain and its home is the directory of the domain' );

    my ($other) = generated( install_dir => '/bogus/hosts', user => 'svc' );
    is( loaded( $other, 'user-data' )->{bootcmd}[-1], 'mkdir -p /home', 'and /home, when a service user runs it' );
};

subtest 'first boot gives /var/log the mode of rsyslog in an override of var.conf' => sub {
    my ( $dir, undef ) = generated();
    my $cmd  = loaded( $dir, 'user-data' )->{bootcmd}[0] // q{};
    my $root = tempdir( CLEANUP => 1 );
    mkdir "$root/$_" for qw{lib etc};

    my $run = sub {
        my $script = $cmd =~ s{/usr/lib/tmpfiles[.]d}{$root/lib}gr =~ s{/etc/tmpfiles[.]d}{$root/etc}gr;
        IPC::Run3::run3( [ 'sh', '-c', $script ], \undef, \my $out, \my $err );
        return ( $? >> 8, $err );
    };

    my $var = "Q /var 0755 - - -\nd /var/log 0755 - - -\nf /var/log/wtmp 0664 root utmp -\n";
    File::Slurper::Temp::write_text( "$root/lib/var.conf", $var );

    my ( $status, $err ) = $run->();
    is( $status, 0, 'without rsyslog, it succeeds' ) or diag $err;
    ok( !-e "$root/etc/var.conf", 'and writes no override, so var.conf of systemd stands' );

    File::Slurper::Temp::write_text( "$root/lib/00rsyslog.conf", "z /var/log 0775 root syslog -\nz /var/log/syslog 0640 syslog adm -\n" );
    ( $status, $err ) = $run->();
    is( $status, 0, 'with rsyslog, it succeeds' ) or diag $err;
    is(
        eval { File::Slurper::read_text("$root/etc/var.conf") } // q{},
        "Q /var 0755 - - -\nd /var/log 0775 root syslog -\nf /var/log/wtmp 0664 root utmp -\n",
        'and the override is var.conf with the line of /var/log from rsyslog, and every other line as it was'
    );

    File::Slurper::Temp::write_text( "$root/lib/var.conf", $var =~ s{^Q[ ]/var[ ]0755}{Q /var 0750}mr );
    $run->();
    like( eval { File::Slurper::read_text("$root/etc/var.conf") } // q{}, qr{^Q[ ]/var[ ]0750[ ]}m, 'a boot after systemd changes var.conf makes the override again from the new one' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
