#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

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
use Test::MockModule qw{strict};
use YAML::XS();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Trog::HV();
use Provisioner::Cookbook();

my $DOMAIN    = 'vm.test.test';
my $GECOS     = q{Sean O'Brien & Co: boss};
my $EMAIL     = q{o'brien&sons@test.test};
my $RESOLVERS = [ '192.168.1.253', '8.8.8.8' ];

# The guest's own configuration, as bin/new_config hands it over.
sub settings {
    return (
        domain        => $DOMAIN,
        ips           => ['192.168.1.10'],
        gateway       => '192.168.1.254',
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
        payload_dir   => '/bogus/domains',

        # What bin/new_config hands over as the ip pool's assignments, which is
        # how a mirror named by bare domain gets resolved to an address.
        ipmap => { 'm.test.test' => '192.168.1.9' },
        @_,
    );
}

# Generate the five, and hand back the directory they landed in.
sub generated {
    my (%extra) = @_;

    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new      => sub { return bless {}, 'Trog::HV' } );
    $hv->redefine( virbr_ip => sub { return '192.168.122.1' } );

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load('ubuntu')->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
    );

    my @written = $recipe->generate_files( $dir, settings(%extra) );
    return ( $dir, \@written );
}

sub loaded {
    my ( $dir, $file ) = @_;
    return YAML::XS::Load( File::Slurper::read_binary("$dir/$file") );
}

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

    # It fetches from whoever wrote the payload, which is this machine, at the
    # basedir out of ipmap.cfg.  It used to be told the hypervisor's domain_dir,
    # which has been the wrong machine since the guest stopped fetching from
    # there -- the same path only by both of them defaulting to /opt/domains.
    like( $setup, qr{transfer.\@192\.168\.122\.251:/bogus/domains/\Q$DOMAIN\E/data\.tar\.gz}, 'from the machine holding the payload, at the path it was written to' );
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
                version => 1,
                config  => [
                    {
                        type        => 'physical',
                        name        => 'ens4',
                        mac_address => Trog::HV->guest_mac( $DOMAIN, 1 ),
                        gateway4    => '192.168.1.254',
                        nameservers => { search => [$DOMAIN], addresses => $RESOLVERS },
                        subnets     => [
                            {
                                type            => 'static',
                                address         => '192.168.1.10',
                                gateway         => '192.168.1.254',
                                dns_search      => [$DOMAIN],
                                dns_nameservers => $RESOLVERS,
                            }
                        ],
                    },
                    {
                        type        => 'physical',
                        name        => 'ens3',
                        mac_address => Trog::HV->guest_mac( $DOMAIN, 0 ),
                        subnets     => [ { type => 'dhcp' } ],
                    },
                ],
            }
        },
        'network-config'
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
CONF
        'the apt configuration, which apt reads whitespace-insensitively'
    );

    # With no mirror there is nothing to redirect apt at, so the whole apt key
    # is now just that conf.  AllowInsecureRepositories went with the mirror:
    # it was there because the one on the hypervisor was unsigned.
    is_deeply( $user_data->{apt}, {}, 'and nothing else under apt, there being no mirror to point at' );
    delete $user_data->{apt};

    # Where a guest sends its logs is Provisioner::Recipe::logshipper now, so the
    # distro recipe configures no forwarder at all.  It used to write one here
    # unconditionally, aimed at the hypervisor whether or not anything there was
    # listening -- and nothing on the guest could tell the difference.
    ok( !exists $user_data->{rsyslog}, 'and no log forwarder, which is a recipe rather than a fact about the distribution' );

    cmp_deeply(
        $user_data,
        {
            fqdn             => $DOMAIN,
            manage_etc_hosts => 'localhost',
            final_message    => 'Boot configuration complete.',
            package_update   => bool(1),
            package_upgrade  => bool(1),

            # atd is how the makefile gets started, make is what runs it, and
            # something has to take mail -- none of which any recipe asked for.
            packages => [qw{nginx mariadb-server sendmail at make}],

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
                    ssh_authorized_keys => [ re(qr/\Assh-rsa \S+ \S+\z/s) ],
                }
            ],

            write_files => [
                { path => '/root/.ssh/id_rsa',     owner => 'root:root', permissions => '0600', defer => bool(1), content => re(qr/BEGIN OPENSSH PRIVATE KEY/) },
                { path => '/root/.ssh/id_rsa.pub', owner => 'root:root', permissions => '0600', defer => bool(1), content => re(qr/\Assh-rsa /) },
                { path => '/root/setup.sh',        owner => 'root:root', permissions => '0775', defer => bool(1), content => re(qr/cloud-init status --wait/) },

                # No mirrorlist, and so nothing left that cloud-init has to write
                # before it installs anything: it was the only defer: false entry.
            ],

            # The newline in the middle of the first of these is as it has always
            # been, and is why runcmd is built as a list rather than written out
            # in the template: a YAML sequence item cannot carry one inline.
            runcmd => [ qq{echo "root:$EMAIL\n" > /etc/aliases }, 'at now -f /root/setup.sh' ],
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

    like( $config, qr/^\s+mac_address: '52:54:00:11:44:22'$/m, 'an all-decimal MAC is quoted' );
    like( $config, qr/^\s+mac_address: 52:54:00:f8:83:fc$/m,   'and one with hex letters is left alone' );

    # 59 is the last sexagesimal digit, so the quoting stops at exactly the
    # point PyYAML stops misreading.
    is( Provisioner::Recipe::ubuntu::_yaml('52:54:00:11:59:22'), q{'52:54:00:11:59:22'}, '59 is still a base-60 digit' );
    is( Provisioner::Recipe::ubuntu::_yaml('52:54:00:11:60:22'), '52:54:00:11:60:22',    'and 60 is not, so it needs no quoting' );

    # It is a scalar rule, and must not reach into a structure being dumped.
    is( Provisioner::Recipe::ubuntu::_yaml( [qw{a b}] ), "- a\n- b", 'a list is dumped as it always was' );
};

subtest 'a guest with no addresses falls back to DHCP on both interfaces' => sub {
    my ( $dir, undef ) = generated( ips => [], gateway => undef );

    my $config = loaded( $dir, 'network-config' )->{network}{config};
    cmp_deeply( $config->[0]{subnets}, [ { type => 'dhcp' } ], 'the bridge asks for one' );
    cmp_deeply( $config->[1]{subnets}, [ { type => 'dhcp' } ], 'as the NAT side always does' );
    ok( !exists $config->[0]{gateway4}, 'and no gateway is claimed for an address it does not have' );
};

subtest 'a guest with addresses and no gateway is refused' => sub {
    like(
        exception { generated( gateway => undef ) },
        qr/MUST SET gateway/,
        'rather than written out with a static subnet routing nowhere'
    );

    like(
        exception { generated( contact_email => undef ) },
        qr/MUST SET contact_email/,
        'and root mail has to have somewhere to go'
    );
};

subtest 'the key is rotated on a real run and kept on a dry one' => sub {
    my $hv = Test::MockModule->new('Trog::HV');
    $hv->redefine( new      => sub { return bless {}, 'Trog::HV' } );
    $hv->redefine( virbr_ip => sub { return '192.168.122.1' } );

    my $dir   = tempdir( CLEANUP => 1 );
    my $build = sub {
        my (%extra) = @_;
        Provisioner::Cookbook->load('ubuntu')->new(
            template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
            output_dir    => $dir,
        )->generate_files( $dir, settings(%extra) );
        return File::Slurper::read_text("$dir/key.rsa");
    };

    my $first = $build->();
    like( $first, qr/BEGIN OPENSSH PRIVATE KEY/, 'a domain with no key gets one' );

    # The guest that is up has the public half of this, so a run that is meant
    # to change nothing must not replace the private half.
    is( $build->( dryrun => 1 ), $first, 'a dry run leaves the one a live guest is using alone' );
    isnt( $build->(), $first, 'and a real run rotates it, the guest being rebuilt around the new one' );
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
    like( $user_data->{apt}{conf}, qr/AllowInsecureRepositories: true;/, 'and unverified repositories are allowed, as they have always been with a mirror' );

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

    like( $mirrorlist->{content}, qr{\Ahttp://192\.168\.1\.9/ubuntu\t}, 'the address out of the pool, with the distribution path on it' );
};

subtest 'a name nothing has an address for is refused' => sub {
    like(
        exception { generated( mirror => 'nowhere.test.test' ) },
        qr/named as a URL instead/,
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

Test::NoWarnings::had_no_warnings();

done_testing;
