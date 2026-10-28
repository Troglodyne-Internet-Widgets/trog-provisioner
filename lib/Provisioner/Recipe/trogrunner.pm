package Provisioner::Recipe::trogrunner;

#ABSTRACT: Make a guest that can run trog-provisioner itself.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Path::Tiny();
use Provisioner::Cookbook();

use YAML::XS();
use Text::Xslate();
use File::Slurper();
use File::Slurper::Temp();
use Provisioner::IPPool();
use Provisioner::Utils();
use URI();
use URI::Split();
use File::Temp();
use List::Util qw{any};
use Clone      qw{clone};
use Trog::Utils();

=head1 Provisioner::Recipe::trogrunner

=head2 SYNOPSIS

    runner.test.test:
        trogrunner:
            # Everything below is optional.
            checkout: 1
            libvirt_version: "10.0.0"

            config:
                # If unset, admin_user, admin_email, admin_keys and gateway
                # come from the configuration of this guest.
                resolvers: ["192.0.2.254", "1.1.1.1"]

                # The pool that the runner takes addresses from.  Without
                # these, each guest it builds has only a lease on the NAT
                # network of its hypervisor: see offers in Provisioner::IPPool.
                addresses: "192.0.2.180-192.0.2.199"
                cidr:      "192.0.2.0/24"

            hypervisors:
                hv1:
                    libvirt_uri: "qemu+ssh://runner@hv1.test.test/system"
                    pool_path:   "/srv/vm-disks/runner"
                    pool_name:   "runner_disks"
                    partition:   "/machine/runner"
                    max_memory:  65536

                    # bin/provision makes the account above, with these
                    # limits.  See ACCOUNTS.
                    account:
                        quota: 500G

            hypervisor_access: least

            # The recipes.yaml of the runner, dumped as written.  Write
            # secrets as store:, never as secret:.  See SECRETS IN recipes.
            recipes:
                _base:
                    _global:
                        install_dir: /opt/domains
                someguest.test.test:
                    nginx:
                        cert_password: "store:someguest/tls/password"

=head2 DESCRIPTION

A guest that can build guests.  It gets a perl that can load this
distribution, and the CPAN modules that the distribution declares.  It also
gets its own F</etc/trog-provisioner>, and a key that a hypervisor accepts if
you ask for one.

The machine that I<runs> the provisioner is a guest like any other.
F<bin/setup_provisioner> is about the machine that I<hosts> the guests, which
is a different machine with different problems.

The checkout is optional (C<checkout: 0>).  A runner that manages its own
repositories, such as a coding agent, already has one.  A second copy under
C<install_dir> is a second copy to keep in step.  Point C<deps_from> at the
path where it clones instead, and the dependencies still install.

=head3 What it needs from the guest, and how long it takes

The build was measured on four vCPUs and 8GB.  Nobody tuned these numbers.
Issue #123 is about measuring the build properly.  The likely answer is more
resources and a build that does less.

A runner builds perl from source and installs the toolchain that the C<perl>
recipe puts on it.  Only then does it start on C<Sys::Virt>, C<Dist::Zilla>
and the forty-odd distributions that this recipe hands to the C<perl> recipe.
Most of the time goes to those distributions, and to their test suites when
C<cpan_notest> is off.  On four vCPUs, this does not fit in the ninety minutes
that C<Trog::Guest> allows for a makefile and its whole postrun queue.

So raise the time limit when you build one:

    TROG_SETUP_TIMEOUT=3h bin/provision runner.example.test

If you forget, nothing breaks.  C<bin/provision> stops waiting and says so.
The queue continues, because C<atd> runs F<scripts/post_install>, not anything
on this end.  You lose the result of the guest test, which is the reason you
provisioned the guest.

=head3 SECRETS IN recipes

The C<recipes> argument is the whole F<recipes.yaml> of the runner.  Read this
section before you write one.

C<bin/new_config> resolves every C<secret:> reference in the I<whole>
configuration before it constructs any recipe.  So it resolves a C<secret:>
inside C<recipes> too, and this recipe gets the password itself.  The password
then goes into the F<recipes.yaml> of the runner and into its C<data.tar.gz>.
From there it goes onto the guest and into every backup of the domain, where
nothing that looks for plaintext finds it.

So write C<store:> instead.  Nothing resolves it, and it arrives here as
written.  L</enrich> turns it back into C<secret:> on the way out.  The runner
gets a F<recipes.yaml> full of references, the same as one written by hand.
The runner resolves them against its own store, which C<store> supplies.

=head3 QUOTAS

A runner can build guests, and a guest uses disk, CPU and memory on the machine
of another person.  Nothing in libvirt holds it to a budget.  There is no
accounting and no limit.  On the system URI, every guest runs as
C<libvirt-qemu>, whoever defined it, so a disk quota has no UID to attach to.

What works is set in the hypervisor blocks above, and the kernel enforces it:

=over 4

=item * C<pool_path> and C<pool_name> together give the runner its own storage
pool.  Put a limit under that path, and the limit is real: a ZFS dataset with a
quota, a project quota on XFS or ext4, or a filesystem of its own.
C<bin/preflight> says which one the hypervisor can use.  Name both.  libvirt
finds a pool by name.  If the name is of a pool that already exists elsewhere,
libvirt ignores the path, and every volume goes into the existing pool.

=item * C<partition> puts every guest that the runner builds into one systemd
slice.  The operator then sets one cap on it with C<systemctl set-property
machine-runner.slice CPUQuota=400%>.

Cap CPU and I/O there, not memory.  A C<MemoryMax> on a slice of virtual
machines kills one of them, and does not refuse the next.  The per-domain
equivalent is worse.  The libvirt documentation warns that
C<< <memtune><hard_limit> >> gets guests OOM-killed.  C<reserve_memory> in
F<hypervisors.conf> is what refuses a guest when memory is short, and it
already exists.  For a budget of the partition, give C<max_memory> in MB.  The
runner then refuses a guest whose memory does not fit in what the guests of the
partition already hold, running or not.  It still refuses one that does not fit
on the host after C<reserve_memory>.  The kernel holds no guest to it, so it
binds a runner that cooperates, as the next paragraph says.

With a C<partition>, the runner counts only its own guests.  C<max_guests>
caps how many the partition holds, and C<cpu_overcommit> is the vCPUs for each
core of the C<CPUQuota> of the slice.  The runner still refuses a guest when
the whole hypervisor has no vCPUs left after C<reserve_cpus>, so it cannot take
the room of the guests outside its partition.  Give the hypervisor block the
C<reserve_memory>, C<reserve_cpus> and C<cpu_overcommit> of the block in the
F<hypervisors.conf> of the operator, because the runner gets no other copy of
them.  Without a C<partition>, every limit counts every guest on the
hypervisor, so a C<max_guests> of a few refuses every build on a busy one.  A
C<max_memory> without a C<partition> is refused.

=back

A runner that cooperates respects both limits.  Neither stops a runner that
names a different pool or partition.  That takes the polkit access driver of
libvirt, which is off by default and is a change to the hypervisor, not to this
guest.  Say which of the two you have before you tell anyone that the runner
has a cap.

=cut

my $ED25519_BITS = 256;

my $REPO = 'https://github.com/Troglodyne-Internet-Widgets/trog-provisioner.git';

=head3 required_recipes

The C<perl> recipe, with what goes into it from CPAN as its C<cpan_deps>.  The
order is important:

=over 4

=item * B<Sys::Virt, pinned>, before anything resolves dependencies.  From a
dependency list, cpan_install takes the newest release.  Its Makefile.PL wants
a libvirt-dev that is much newer than this guest has.  The build reports this forty
minutes into the build, in a message about pkg-config, not about the order.
The pin is to C<libvirt_version> if you set one.  If not, it is to the libvirt
version that pkg-config reports on the guest when the step runs.  That is
correct when the runner and the hypervisor use the same distribution.

=item * B<The dependencies of the checkout>, and of each path in C<deps_from>,
from dzil.  Dist::Zilla itself comes with the perl, so nothing here asks for
it.

=back

The closure gets the configuration without the schema defaults.  So it puts the
defaults of this recipe under it, because C<checkout_dir> has one.  The perl
recipe validates what it gets.

=cut

sub required_recipes {
    my ($self) = @_;

    # The perl recipe builds /opt/perl5/$version with cpanm, cpm, Module::Build
    # and Dist::Zilla.  Everything else here is CPAN or configuration.
    return (
        perl => sub {
            my %opts = ( Provisioner::Cookbook->defaults('trogrunner'), @_ );
            my $sys_virt =
              $opts{libvirt_version}
              ? { install => ["Sys::Virt\@$opts{libvirt_version}"] }
              : { pin     => { module => 'Sys::Virt', pkgconfig => 'libvirt' } };

            return (
                cpan_deps => [
                    $sys_virt,
                    ( $opts{checkout} ? { dzil => Path::Tiny::path( @opts{qw{install_dir domain checkout_dir}} )->stringify } : () ),
                    ( map { { dzil => $_ } } @{ $opts{deps_from} // [] } ),
                ],
            );
        },
    );
}

=head2 $bool = $recipe->is_multi_tenant()

False.  A machine has one F</etc/trog-provisioner>, and here it is a symlink
into the directory of this domain.  A second domain does not get its own
runner.  It points that link at itself, and takes the address pool in
F<ips.db> with it.

=cut

sub is_multi_tenant { return 0 }

sub args {
    return (
        type       => 'object',
        properties => {
            checkout => { type => 'boolean', default => 1 },

            # Relative to install_dir/domain, and never the domain directory.
            # service_user makes that first, and git clone refuses a target
            # that is not empty.
            checkout_dir => { type => 'string', default => 'trog-provisioner' },

            # HTTPS, not ssh, because a new guest has no key registered anywhere.
            repo_url    => { type => 'string', default => $REPO },
            repo_branch => { type => 'string', default => 'master' },

            # Which Sys::Virt to pin.  Empty asks the guest for the version of
            # its libvirt-dev.  See required_recipes.
            #
            # Not a number by default.  This recipe must not load Trog::HV to
            # ask a hypervisor (see Provisioner::Recipe), so a number here is a
            # guess that goes stale.
            libvirt_version => { type => 'string', default => q{} },

            # Absolute paths of checkouts that this recipe did not make, to
            # install their dzil dependencies.  The operator names them, because
            # only the operator knows where a runner clones its repositories.
            deps_from => { type => 'array', items => { type => 'string' }, default => [] },

            # What every guest the runner builds shares, which L</enrich>
            # folds into the _base of its recipes.yaml.  The defaults are on
            # the members, not on config, so a domain that sets one member
            # keeps the rest.
            config => {
                type       => 'object',
                default    => {},
                properties => {
                    basedir       => { type => 'string', default => '/opt/domains' },
                    admin_user    => { type => 'string' },
                    admin_email   => { type => 'string' },
                    admin_gecos   => { type => 'string', default => 'Administrator' },
                    admin_keys    => { type => 'array',  items   => { type => 'string' }, default => [] },
                    gateway       => { type => 'string', default => q{} },
                    resolvers     => { type => 'array',  items   => { type => 'string' }, default => [qw{1.1.1.1 8.8.8.8}] },
                    transfer_user => { type => 'string', default => q{} },
                    transfer_ip   => { type => 'string', default => q{} },
                    transfer_port => { type => 'string', default => q{} },
                    addresses     => { type => 'string', default => q{} },
                    cidr          => { type => 'string', default => q{} },
                    nameservers   => { type => 'object', default => {}, additionalProperties => { type => 'string' } },
                },
            },

            # Empty means that the runner is its own hypervisor, which is what
            # libvirt does when nothing says otherwise.
            hypervisors => {
                type                 => 'object',
                default              => {},
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{libvirt_uri}],
                    properties => {
                        libvirt_uri    => { type => 'string' },
                        pool_path      => { type => 'string' },
                        pool_name      => { type => 'string' },
                        partition      => { type => 'string' },
                        domain_dir     => { type => 'string' },
                        bridge_device  => { type => 'string' },
                        virbr_device   => { type => 'string' },
                        reserve_memory => { type => 'integer' },
                        reserve_cpus   => { type => 'integer' },
                        reserve_disk   => { type => 'integer' },
                        cpu_overcommit => { type => 'integer' },
                        max_guests     => { type => 'integer' },
                        max_memory     => { type => 'integer', minimum => 1 },

                        # The account of the runner on this hypervisor, which
                        # bin/provision makes and bin/destroy takes away.  See
                        # ACCOUNTS.  The user is the one in libvirt_uri, and
                        # the pool and the slice are the keys above.
                        account => {
                            type       => 'object',
                            required   => [qw{quota}],
                            properties => {
                                quota     => { type => 'string' },
                                cpu_quota => { type => 'string' },
                                io_weight => { type => 'integer' },
                            },
                            additionalProperties => 0,
                        },
                    },
                },
            },

            recipes => { type => 'object', default => {} },

            # A keepass database in the data directory of this domain, to
            # install as the store of the runner.  Empty is correct too, because
            # bin/preflight wants only recipes.yaml and
            # admin_authorized_keys.
            store => { type => 'string', default => q{} },

            hypervisor_access  => { type => 'string',  enum    => [qw{none least full}], default => 'none' },
            restrict_key_to_ip => { type => 'boolean', default => 1 },
        },
    );
}

=head3 formatters

C<yaml>, which dumps a copy of a structure with every C<store:GROUP/TITLE/FIELD>
string in it, at any depth, written back as C<secret:GROUP/TITLE/FIELD>.  See
L</SECRETS IN recipes> for the reason.

=cut

sub formatters {
    return (
        yaml => Text::Xslate::html_builder(
            sub ($node) {
                my $copy = clone($node);
                foreach my $slot ( map { $_->[1] } Trog::Utils::slots_in( \$copy ) ) {

                    # The same test that Trog::Secrets::needed makes of a
                    # secret: reference, a prefix at the start and nothing more.
                    next if ref $$slot || !defined $$slot || index( $$slot, 'store:' ) != 0;
                    $$slot = 'secret:' . substr( $$slot, length 'store:' );
                }
                return YAML::XS::Dump($copy);
            }
        ),
    );
}

=head3 enrich

Fills in the identity of the runner from the identity of the guest, and folds
C<config> into the C<_global> of C<_base> in C<recipes>, which is where the
runner reads it.  The pool is one key there, C<ip_pool>, rather than two, and a
setting left empty is left out, so that the runner falls back to its own answer
for it rather than to an empty string.

Splits the URI of each hypervisor into the host, user and port that
C<ssh-keyscan> needs.  Dies if C<checkout_dir> or C<store> is not a relative
path under the domain directory, or if a hypervisor URI has no host or is
remote without ssh.

=cut

# Dies unless $path, the value of $field, is a relative path that stays under
# the domain directory.
my sub under_the_domain ( $path, $field ) {
    die "trogrunner: $field is relative to the domain directory, so '$path' cannot start with a slash\n"
      if index( $path, '/' ) == 0;
    die "trogrunner: $field is relative to the domain directory, and '$path' climbs out of it\n"
      if any { $_ eq '..' } split( m{/}, $path );

    return 1;
}

# The transport, host, user and port of a libvirt URI, or nothing when it has
# no scheme to read.  URI does not know the driver+transport scheme of libvirt,
# and gives an object that cannot say the host, user or port, so the authority
# is parsed again under the ssh scheme, as Trog::HV does.
my sub uri_parts ($uri) {
    my ( $scheme, $authority ) = $uri ? URI::Split::uri_split($uri) : ();
    return () unless $scheme;

    my ( undef, $transport ) = split( quotemeta('+'), $scheme, 2 );
    my $server = $authority ? URI->new("ssh://$authority") : undef;
    return ( $transport // q{}, $server ? ( $server->host, $server->user, $server->port ) : () );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Unless told otherwise, the runner administers its guests as whoever
    # administers this one, on the same network.  These come from the _global
    # that built this guest.
    #
    # bin/new_config refuses to generate anything without admin_user,
    # admin_gecos, admin_email, gateway and resolvers, or without keys in
    # admin_authorized_keys.  A runner with any of them empty cannot build a
    # guest.
    $opts{config}{admin_user}  //= $opts{admin_user};
    $opts{config}{admin_email} //= $opts{admin_email};

    # ||=, not //=, because the schema defaults these two to an empty string,
    # which //= keeps.
    $opts{config}{gateway} ||= $opts{gateway};

    # A list, so an unset value is an empty list, not an empty string.
    $opts{config}{admin_keys} = $opts{admin_keys}
      unless @{ $opts{config}{admin_keys} // [] };

    # The recipes on top, because a runner that names a setting of its own in
    # the file it is handed means it.
    my $config = $opts{config};
    my $said   = sub ($key) {
        my $value = $config->{$key};

        return 0 unless defined $value;
        return scalar @$value      if ref $value eq 'ARRAY';
        return scalar keys %$value if ref $value eq 'HASH';
        return $value ne q{};
    };
    my %is_pool = map { $_ => 1 } qw{addresses cidr};
    my %global  = map { $_ => $config->{$_} } grep { !$is_pool{$_} && $said->($_) } keys %$config;
    my %pool    = map { $_ => $config->{$_} } grep { $said->($_) } keys %is_pool;
    $global{ip_pool} = \%pool if %pool;
    $opts{recipes}{_base}{_global} = { %global, %{ $opts{recipes}{_base}{_global} // {} } };

    die "trogrunner: checkout_dir cannot be empty, and cannot be '.': git clone will not drop a repo into the domain directory, which already exists by then\n"
      if $opts{checkout} && ( !$opts{checkout_dir} || $opts{checkout_dir} eq '.' );

    # Both go into a path under the domain directory, so an absolute path
    # points somewhere else.  `store: /etc/trog-provisioner/secrets.kdbx`
    # renders as /opt/domains/<domain>//etc/..., and fails as a missing file.
    under_the_domain( $opts{checkout_dir}, 'checkout_dir' ) if $opts{checkout};
    under_the_domain( $opts{store},        'store' )        if $opts{store};

    foreach my $name ( sort keys %{ $opts{hypervisors} } ) {
        my $block = $opts{hypervisors}{$name};
        my ( $transport, @server ) = uri_parts( $block->{libvirt_uri} );
        die "trogrunner: could not read a host out of the libvirt_uri for hypervisor '$name': $block->{libvirt_uri}\n"
          unless defined $transport;
        @{$block}{qw{ssh_host ssh_user ssh_port}} = @server;

        # Trog::HV needs the filesystem of a remote hypervisor as well as its
        # libvirt, so the runner must reach it over ssh.  Find that out here,
        # not on the guest.
        die "trogrunner: hypervisor '$name' is remote, so its libvirt_uri needs an ssh transport, e.g. qemu+ssh://user\@$block->{ssh_host}/system\n"
          if $block->{ssh_host} && $transport ne 'ssh';

        # OpenAPIv3 cannot make one key need another, and Trog::HV::Libvirt
        # would refuse this only on the runner.
        die "trogrunner: hypervisor '$name' gives max_memory and no partition, and a budget of memory is that of a partition.  reserve_memory already caps the host.\n"
          if $block->{max_memory} && !$block->{partition};

        next unless $block->{account};

        # Here, and not on the hypervisor twenty minutes into the build of the
        # runner.
        die "trogrunner: hypervisor '$name' asks for an account, and hypervisor_access is none, so nothing would make it\n"
          if $opts{hypervisor_access} eq 'none';
        die "trogrunner: hypervisor '$name' asks for an account, which needs pool_name and pool_path: the pool is where its quota is\n"
          unless $block->{pool_name} && $block->{pool_path};
        die "trogrunner: hypervisor '$name' asks for an account for the user in its libvirt_uri, and $block->{libvirt_uri} names no user\n"
          unless $block->{ssh_user};
    }

    warn "trogrunner: hypervisor_access is $opts{hypervisor_access}, and no hypervisor is named, so no hypervisor lets the runner in\n"
      if $opts{hypervisor_access} ne 'none' && !%{ $opts{hypervisors} };

    return %opts;
}

=head3 %grant = Provisioner::Recipe::trogrunner->grant($block)

What the C<trogrunner> block of a domain asks for as hypervisor access:
C<access>, C<restrict> and C<hypervisors>.  Returns an empty list if it asks
for none, which is the default.

It reads the defaults from C<args()>, because a second copy of them can drift.

Takes the block as written, not a validated one, because L</outside_steps>
does, for the reason that it gives.

=cut

sub grant {
    my ( $class, $block ) = @_;
    return () unless ref $block eq 'HASH';

    my %args   = $class->args();
    my $props  = $args{properties};
    my $access = $block->{hypervisor_access} // $props->{hypervisor_access}{default};

    return () if !defined $access || $access eq 'none';

    return (
        access      => $access,
        restrict    => $block->{restrict_key_to_ip} // $props->{restrict_key_to_ip}{default},
        hypervisors => ( ref $block->{hypervisors} eq 'HASH' ? $block->{hypervisors} : {} ),
    );
}

# The reference in the store of the key that a hypervisor is asked to trust.
my sub key_ref ($domain) { return "secret:trogrunner/$domain-hypervisor-key/password" }

# The public half beside the domain, which bin/destroy reads instead of the
# store.
my sub pub_file (%context) { return "$context{domain_dir}/hypervisor-key.pub" }

=head3 $line = Provisioner::Recipe::trogrunner->key_line($domain, $restrict, %context)

The F<authorized_keys> line of the runner of C<$domain>: the public half of
its key in C<$context{secrets}>, with C<from=> and the address that the domain
holds in the pool when C<$restrict> is true.  C<%context> is the context of a
step, as L<Trog::Steps> gives it.  It writes the public half to
F<hypervisor-key.pub> in C<$context{domain_dir}>.

A dry run has no store, so it reads that file instead, and returns undef when
there is none.  Dies when the store has no key outside a dry run, or holds
something that is not a key.  Warns when C<$restrict> is true and the domain
holds no address, and leaves C<from=> out.

=cut

sub key_line {
    my ( $class, $domain, $restrict, %context ) = @_;

    my $private = $context{secrets}{ key_ref($domain) };
    my $pubkey;
    if ( defined $private && length $private ) {    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- a key of "0" is still a key

        # ssh_pubkey_from_private reads a key from a file, so the key goes to a
        # temporary one that only this user can read, for as long as that takes.
        my $tmp = File::Temp->new( UNLINK => 1 );
        chmod 0600, $tmp->filename;
        print {$tmp} "$private\n";
        $tmp->flush();

        my $half = eval { Provisioner::Utils::ssh_pubkey_from_private( $tmp->filename ) };
        die "Could not read the public half of $domain's hypervisor key; the store may be holding something that is not one.\n$@"
          unless $half;

        # The comment names the line, so that a reader of authorized_keys can
        # tell whose it is and remove it by hand.
        $pubkey = "$half trog-provisioner runner $domain";
        File::Slurper::Temp::write_binary( pub_file(%context), "$pubkey\n" );
    }
    elsif ( $context{dryrun} ) {
        $pubkey = eval { File::Slurper::read_text( pub_file(%context) ) } // return undef;
        chomp $pubkey;
    }
    else {
        die "$domain wants hypervisor access and the store had no key for it\n";
    }

    # from="<address>" when the domain holds one.  The address is stable,
    # because a new provision keeps the address of the domain.  Only
    # bin/destroy gives it back.
    return $pubkey unless $restrict;
    my $ip = eval { Provisioner::IPPool::held_by($domain) };
    warn "$domain holds no address in the ip pool, so its key on the hypervisors is not restricted to an address.  A lease can change.\n" unless $ip;
    return $ip ? qq{from="$ip" $pubkey} : $pubkey;
}

# The key material of the public half beside the domain, or undef when there is
# none.  Dies on one too short to be a key, because a short string matches half
# of an authorized_keys file.
my sub pub_material (%context) {
    my $pubkey = eval { File::Slurper::read_text( pub_file(%context) ) } // return undef;
    my ($material) = ( split( q{ }, $pubkey ) )[1];
    die "The public key in " . pub_file(%context) . " does not look like one; refusing to match on it\n"
      if !defined $material || length($material) <= 32;
    return $material;
}

# What a dry run says when it has no line to let in.
my sub key_unknown ( $domain, $user ) {
    return {
        what => "let the key of $domain log in as $user, once the store gives it, which a dry run does not open",
        done => sub { 0 },
        do   => sub { die "There is no key of $domain to let in\n" },
    };
}

=head3 outside_steps

What a runner needs on its hypervisors, from C<grant> above.  Nothing to make
while C<hypervisor_access> is C<none>, the default.  Otherwise, for each
hypervisor in the C<hypervisors> block, in the order of the names, one of
these:

=over 4

=item * With an C<account>, the account, from C<runner_account_steps> of
L<Trog::HV::Libvirt>, and then the key of the runner in the
F<authorized_keys> of the account, through C<runner_key_steps>.  Both run as
the account of the block of the same name in F<hypervisors.conf>, which needs
sudo for everything.  So the key of the operator never goes into the account
of the runner.  See L</ACCOUNTS>.

=item * Without one, the key of the runner in the F<authorized_keys> of the
user of C<libvirt_uri>, written as that user.  That user must exist, and let
the operator in.

=back

The line of the key is the public half of the key in the store, with C<from=>
and the address that the domain holds in the pool, when C<restrict_key_to_ip>
is on.  A domain that holds no address gets a warning, and its key goes in
unrestricted.  The public half also goes beside the domain as
F<hypervisor-key.pub>.  A dry run has no store, so it reads that file.

F<bin/destroy> takes each step back, last first: the key, and then the account.
It reads the key from F<hypervisor-key.pub>, so a teardown never stops to ask
for the password of the store.  It removes every line that has the key
material in it, not only the line that a provision wrote, because somebody can
edit the C<from=> or the comment on the hypervisor.  The key is made for one
domain and kept in the store, so no other line can have it.  The account does
not go while its pool holds the disk of a guest.  See C<runner_removal_steps>.
The steps of a block with C<hypervisor_access> of C<none> have only the
revert, so that a teardown still takes back what a provision let in before
somebody took the access away.

Takes the block as written, because F<bin/destroy> has a configuration and no
recipe object.

=head3 ACCOUNTS

An C<account> block in a C<hypervisors> entry gives the runner an account of
its own there.  The user is the user of C<libvirt_uri>, and the pool and the
slice are its C<pool_name>, C<pool_path> and C<partition>:

    hypervisors:
        hv1:
            libvirt_uri: "qemu+ssh://runner@hv1.test.test/system"
            pool_name:   "runner_disks"
            pool_path:   "/srv/vm-disks/runner"
            partition:   "/machine/runner"
            account:
                quota:     500G      # required: of the ZFS dataset of the pool
                cpu_quota: "400%"    # CPUQuota of the slice
                io_weight: 50        # IOWeight of the slice

The parent of C<pool_path> must be where a ZFS dataset is mounted, because the
quota is a quota of a child dataset.  C<cpu_quota> and C<io_weight> need a
C<partition>.  C<runner_account_plan> in L<Trog::HV::Libvirt> checks the
values when F<bin/provision> builds the runner, before its makefile starts.
F<bin/runner_account> makes the same account by hand.

=cut

sub outside_steps {
    my ( $class, $domain, %opts ) = @_;

    # Every hypervisor that the block names, with or without access, so that a
    # teardown takes back what a provision let in under an earlier
    # configuration.
    my %grant       = $class->grant( \%opts );
    my $hypervisors = ref $opts{hypervisors} eq 'HASH' ? $opts{hypervisors} : {};

    # One line for every hypervisor of a run, so the warning about the address
    # comes once.
    my $line;
    my $line_of = sub (%context) { return $line //= $class->key_line( $domain, $grant{restrict}, %context ) };

    my @steps;
    foreach my $name ( sort keys %$hypervisors ) {
        my $block = $hypervisors->{$name};
        my $uri   = $block->{libvirt_uri} or die "$domain names a hypervisor '$name' with no libvirt_uri\n";
        my ( undef, undef, $user ) = uri_parts($uri);

        if ( ref $block->{account} eq 'HASH' ) {
            my %plan = ( user => $user, %{$block}{qw{pool_name pool_path partition}}, %{ $block->{account} } );
            delete @plan{ grep { !defined $plan{$_} } keys %plan };
            push @steps, {
                id      => "trogrunner:account:$name",
                machine => { hypervisor => $name },
                when    => 'secrets',
                apply   => sub ( $hv, %context ) { return $hv->runner_account_steps( $hv->runner_account_plan(%plan) ) },
                revert  => sub ( $hv, %context ) { return $hv->runner_removal_steps( $hv->runner_account_plan(%plan) ) },
              },
              {
                id      => "trogrunner:key:$name",
                machine => { hypervisor => $name },
                when    => 'secrets',
                apply   => sub ( $hv, %context ) {
                    my $key = $line_of->(%context) // return key_unknown( $domain, $user );
                    return $hv->runner_key_steps( $user, $key );
                },
                revert => sub ( $hv, %context ) {
                    my $material = pub_material(%context) // return ();
                    return $hv->runner_key_removal_steps( $user, $material );
                },
              };
            next;
        }

        push @steps, {
            id      => "trogrunner:key:$name",
            machine => { uri => $uri },
            when    => 'secrets',
            apply   => sub ( $machine, %context ) {
                my $as  = $machine->ssh_user   // 'the connecting user';
                my $key = $line_of->(%context) // return key_unknown( $domain, $as );
                return {
                    what => "let the key of $domain log in as $as on $name",
                    done => sub {
                        my $ak = $machine->authorized_keys;
                        $machine->file_exists($ak) && any { $_ eq $key } split m/\n/, $machine->read_text($ak) // q{};
                    },
                    do => sub {
                        $machine->append_line( $machine->authorized_keys, $key )
                          or die "Could not authorize $domain on $name (" . $machine->describe . ")\n";
                    },
                };
            },
            revert => sub ( $machine, %context ) {
                my $material = pub_material(%context) // return ();
                my $ak       = $machine->authorized_keys;
                return {
                    what => "take the key of $domain away from " . ( $machine->ssh_user // 'the connecting user' ) . " on $name",
                    done => sub { !$machine->file_exists($ak) || index( $machine->read_text($ak) // q{}, $material ) < 0 },
                    do   => sub {
                        my $contents = $machine->read_text($ak);
                        die "Could not read $ak on $name; refusing to rewrite it blind\n" unless $contents;
                        $machine->write_text( $ak, join( q{}, map { "$_\n" } grep { index( $_, $material ) < 0 } split m/\n/, $contents ) )
                          or die "Could not write $ak on $name\n";
                    },
                };
            },
        };
    }

    # Without access there is nothing to make, and only what to take back.
    delete $_->{apply} for %grant ? () : @steps;
    return @steps;
}

sub template_files {
    return (
        'trogrunner.admin_authorized_keys.tt' => 'trogrunner.admin_authorized_keys',
        'trogrunner.recipes.yaml.tt'          => 'trogrunner.recipes.yaml',
        'trogrunner.hypervisors.conf.tt'      => 'trogrunner.hypervisors.conf',
        'trogrunner.profile.tt'               => 'trogrunner.profile',
    );
}

=head3 datadirs

The configuration directory, relative to install_dir/domain.  It exists before
the fragment runs, with the same owner as the rest of the domain.  The fragment
links the F</etc/trog-provisioner> of the guest to it.

The runner creates C<ips.db> in there the first time it assigns an address.
This database records which guest holds which address.  In a directory that
root owns, the first C<bin/new_config> on the runner fails with a SQLite
error.  Because it is under C<install_dir>, the next rebuild salvages the
database.

=cut

sub datadirs {
    return qw{etc/trog-provisioner};
}

=head3 guest_secrets

The key that a hypervisor is asked to trust.  It is in the secret store, not in
the domain directory.

This declares the key even if C<hypervisor_access> is not set, because this is
a class method and cannot see it.  L</remote_files> has the same limit.  This
is not a hole.  The setting decides whether C<bin/provision> writes the public
half into an F<authorized_keys>.  A private key with mode 0600 on a guest that
no machine trusts opens nothing.

The key stays in the store, and is not made again on each provision.  So a
rebuild gets the same key, and the line that the hypervisor has still matches.

The key is ed25519, which keeps an F<authorized_keys> line short enough to
read, and is also why F<bin/preflight> suggests it.  The secret is the private
key as text, without the last newline.
L<Provisioner::Utils/write_ssh_keypair> makes it so that OpenSSH and CryptX can
both read it.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        "$install_dir/$domain/.ssh/id_ed25519" => {
            ref      => key_ref($domain),
            generate => sub {
                my $dir  = File::Temp::tempdir( CLEANUP => 1 );
                my $path = "$dir/id_ed25519";

                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => $ED25519_BITS, 'trog-provisioner runner' );

                chomp( my $key = File::Slurper::read_text($path) );
                return $key;
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head3 remote_files

The configuration directory and the checkout, salvaged off the guest that is
replaced.

The important file in the first is C<ips.db>.  The runner made it the first
time it assigned an address, and it is the only record of which guest holds
which address.  Without it, the next guest can get an address that something
already has.

The whole directory, not that one file, because C<bin/new_config> fetches
these with C<get_dir>.  An entry that is not a directory makes rsync fail.

Both paths are always returned, because this is a class method and cannot see
C<checkout>.  A path that is not on the guest is not an error for the salvage.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        "$install_dir/$domain/etc/trog-provisioner/" => 'etc/trog-provisioner/',
        "$install_dir/$domain/trog-provisioner/"     => 'trog-provisioner/',
    );
}

=head3 remote_skip

The private key, and the secret store of the runner.  A secret salvaged off a
guest goes into the domain directory, then into C<data.tar.gz> and every
backup.  C<remote_skip> exists to prevent that.

B<Not> the rendered configuration files, although each provision renders them
again.  The C<data> target unpacks the payload before any recipe fragment
runs, so the rendered copy replaces the salvaged one anyway.  And if every file
in a directory is skipped, the directory comes off the guest empty.  That looks
the same as a failed fetch, and the salvage-gap check refuses to rebuild over
it.

=cut

sub remote_skip {
    return qw{id_ed25519 secrets.kdbx};
}

sub tests {
    return qw{trogrunner.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves the checkout that this recipe clones.  Only the host of
the default is declared, because C<fetch_hosts> is asked of the class without
a configuration.  A C<repo_url> that points somewhere else goes directly
upstream.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;
    return Provisioner::Utils::host_of( $opts{repo_url} // $REPO ) || ();
}

1;
