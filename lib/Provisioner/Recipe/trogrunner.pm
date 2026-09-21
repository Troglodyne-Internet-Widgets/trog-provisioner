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
use Provisioner::Utils();
use URI();
use URI::Split();
use File::Temp();
use List::Util qw{any};

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
                # these, every guest it builds stops on "cannot auto-assign IP".
                addresses: "192.0.2.180-192.0.2.199"
                cidr:      "192.0.2.0/24"

            hypervisors:
                hv1:
                    libvirt_uri: "qemu+ssh://runner@hv1.test.test/system"
                    pool_path:   "/srv/vm-disks/runner"
                    pool_name:   "runner_disks"
                    partition:   "/machine/runner"

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
pool.  Put that path on a filesystem with a limit, for example C<zfs create -o
quota=500G tank/vm-disks/runner>, and the limit is real.  Name both.  libvirt
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
already exists.

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
dependency list, cpanm takes the newest release.  Its Makefile.PL wants a
libvirt-dev that is much newer than this guest has.  cpanm reports this forty
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

    # The perl recipe builds /opt/perl5/$version with cpanm, Module::Build and
    # Dist::Zilla.  Everything else here is CPAN or configuration.
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
                    basedir        => { type => 'string', default => '/opt/domains' },
                    admin_user     => { type => 'string' },
                    admin_email    => { type => 'string' },
                    admin_gecos    => { type => 'string', default => 'Administrator' },
                    admin_keys     => { type => 'array',  items   => { type => 'string' }, default => [] },
                    gateway        => { type => 'string', default => q{} },
                    resolvers      => { type => 'array',  items   => { type => 'string' }, default => [qw{1.1.1.1 8.8.8.8}] },
                    dhcp_devname   => { type => 'string', default => 'ens3' },
                    bridge_devname => { type => 'string', default => 'ens4' },
                    transfer_user  => { type => 'string', default => q{} },
                    transfer_ip    => { type => 'string', default => q{} },
                    transfer_port  => { type => 'string', default => q{} },
                    addresses      => { type => 'string', default => q{} },
                    cidr           => { type => 'string', default => q{} },
                    nameservers    => { type => 'object', default => {}, additionalProperties => { type => 'string' } },
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

=head2 \%global = _globals_of($config)

The C<config> of this recipe as the C<_global> of a F<recipes.yaml>.  The pool
is one key there rather than two, and a setting left empty is left out, so that
the runner falls back to its own answer for it rather than to an empty string.

=cut

sub _globals_of {
    my ($config) = @_;

    my $said = sub {
        my ($key) = @_;
        my $value = $config->{$key};

        return 0 unless defined $value;
        return scalar @$value      if ref $value eq 'ARRAY';
        return scalar keys %$value if ref $value eq 'HASH';
        return $value ne q{};
    };

    my %is_pool = map { $_ => 1 } qw{addresses cidr};

    my %global = map { $_ => $config->{$_} } grep { !$is_pool{$_} && $said->($_) } keys %$config;

    my %pool = map { $_ => $config->{$_} } grep { $said->($_) } keys %is_pool;
    $global{ip_pool} = \%pool if %pool;

    return \%global;
}

=head3 formatters

C<yaml>, which dumps a structure and writes its C<store:> references back as
C<secret:>.  See L</SECRETS IN recipes> for the reason.

=cut

sub formatters {
    return (
        yaml => Text::Xslate::html_builder( sub { return YAML::XS::Dump( _restore_refs( $_[0] ) ) } ),
    );
}

=head3 enrich

Fills in the identity of the runner from the identity of the guest, and folds
C<config> into the C<_global> of C<_base> in C<recipes>, which is where the
runner reads it.  Splits the
URI of each hypervisor into the host, user and port that C<ssh-keyscan> needs.
Dies if C<checkout_dir> or C<store> is not a relative path under the domain
directory, or if a hypervisor URI has no host or is remote without ssh.

=cut

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
    $opts{recipes}{_base}{_global} = { %{ _globals_of( $opts{config} ) }, %{ $opts{recipes}{_base}{_global} // {} } };

    die "trogrunner: checkout_dir cannot be empty, and cannot be '.': git clone will not drop a repo into the domain directory, which already exists by then\n"
      if $opts{checkout} && ( !$opts{checkout_dir} || $opts{checkout_dir} eq '.' );

    # Both go into a path under the domain directory, so an absolute path
    # points somewhere else.  `store: /etc/trog-provisioner/secrets.kdbx`
    # renders as /opt/domains/<domain>//etc/..., and fails as a missing file.
    _under_the_domain( $opts{checkout_dir}, 'checkout_dir' ) if $opts{checkout};
    _under_the_domain( $opts{store},        'store' )        if $opts{store};

    foreach my $name ( sort keys %{ $opts{hypervisors} } ) {
        my $block = $opts{hypervisors}{$name};
        my $parts = _ssh_parts( $block->{libvirt_uri} )
          or die "trogrunner: could not read a host out of the libvirt_uri for hypervisor '$name': $block->{libvirt_uri}\n";

        # Trog::HV needs the filesystem of a remote hypervisor as well as its
        # libvirt, so the runner must reach it over ssh.  Find that out here,
        # not on the guest.
        die "trogrunner: hypervisor '$name' is remote, so its libvirt_uri needs an ssh transport, e.g. qemu+ssh://user\@$parts->{host}/system\n"
          if $parts->{host} && !$parts->{ssh};

        @{$block}{qw{ssh_host ssh_user ssh_port}} = @{$parts}{qw{host user port}};
    }

    return %opts;
}

sub _under_the_domain {
    my ( $path, $field ) = @_;

    die "trogrunner: $field is relative to the domain directory, so '$path' cannot start with a slash\n"
      if index( $path, '/' ) == 0;
    die "trogrunner: $field is relative to the domain directory, and '$path' climbs out of it\n"
      if any { $_ eq '..' } split( m{/}, $path );

    return 1;
}

=head3 $copy = _restore_refs($node)

Returns a copy of C<$node> with every C<store:GROUP/TITLE/FIELD> string turned
back into C<secret:GROUP/TITLE/FIELD>, at any depth.  See
L</SECRETS IN recipes>.

=cut

sub _restore_refs {
    my ($node) = @_;

    return [ map { _restore_refs($_) } @$node ]                       if ref $node eq 'ARRAY';
    return { map { $_ => _restore_refs( $node->{$_} ) } keys %$node } if ref $node eq 'HASH';
    return $node                                                      if ref $node || !defined $node;

    return $node unless index( $node, 'store:' ) == 0;

    # The same test that Trog::Secrets::needed makes of a secret: reference, a
    # prefix at the start and nothing more.
    return 'secret:' . substr( $node, length 'store:' );
}

=head3 $parts = _ssh_parts($uri)

Returns the ssh half of a libvirt connection URI as a hash reference: C<ssh>
(1 if the transport is ssh, else 0), C<host>, C<user> and C<port>.  Returns
undef if C<$uri> is empty or has no scheme.

URI does not know the driver+transport scheme, and returns an object that
cannot give the host, user or port.  So this splits the URI generically, and
parses the authority again under the ssh scheme.  Trog::HV::_parse_uri does the same.

=cut

sub _ssh_parts {
    my ($uri) = @_;
    return undef unless $uri;

    my ( $scheme, $authority ) = URI::Split::uri_split($uri);
    return undef unless $scheme;

    my ( undef, $transport ) = split( quotemeta('+'), $scheme, 2 );
    my $server = $authority ? URI->new("ssh://$authority") : undef;

    return {
        ssh  => ( defined $transport && $transport eq 'ssh' ) ? 1             : 0,
        host => $server                                       ? $server->host : undef,
        user => $server                                       ? $server->user : undef,
        port => $server                                       ? $server->port : undef,
    };
}

=head3 %grant = Provisioner::Recipe::trogrunner->grant($block)

What the C<trogrunner> block of a domain asks for as hypervisor access:
C<access>, C<restrict> and C<hypervisors>.  Returns an empty list if it asks
for none, which is the default.

This is here and not in F<bin/provision>, which acts on it, because the
defaults are in C<args()>.  A second copy of them in a script can drift.

Takes the block as written, not a validated one.  A script asks this long after
C<bin/new_config> ran, and it has a configuration but no recipe object.

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

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        "$install_dir/$domain/.ssh/id_ed25519" => {
            ref      => "secret:trogrunner/$domain-hypervisor-key/password",
            generate => \&_hypervisor_key,
            owner    => 'root:root',
            mode     => '0600',
        },
    );
}

=head3 $private_key = _hypervisor_key()

Makes a new ed25519 key pair and returns the private key as text, without the
last newline.  Provisioner::Utils::write_ssh_keypair makes the key so that
OpenSSH and CryptX can both read it.  See its POD.  ed25519 keeps an
authorized_keys line short enough to read, which is also why bin/preflight
suggests it.

=cut

sub _hypervisor_key {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $path = "$dir/id_ed25519";

    Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => $ED25519_BITS, 'trog-provisioner runner' );

    return ( File::Slurper::read_text($path) =~ s/\n\z//r );
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
