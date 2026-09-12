package Provisioner::Recipe::trogrunner;

#ABSTRACT: Make a guest that can run trog-provisioner itself.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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

=head1 Provisioner::Recipe::trogrunner

=head2 SYNOPSIS

    runner.test.test:
        trogrunner:
            # Everything below is optional.
            checkout: 1
            libvirt_version: "10.0.0"

            config:
                # Inherited from this guest's own when unset: admin_user,
                # admin_email, admin_key and gateway.
                resolvers: "192.168.1.254, 1.1.1.1"

                # The pool the runner hands addresses out of.  Without these it
                # has none to give, and every guest it tries to build stops on
                # "cannot auto-assign IP".
                addresses: "192.168.1.180-192.168.1.199"
                cidr:      "192.168.1.0/24"

            hypervisors:
                hydra:
                    libvirt_uri: "qemu+ssh://runner@hydra.test.test/system"
                    pool_path:   "/pool/vm-disks/runner"
                    pool_name:   "runner_disks"
                    partition:   "/machine/runner"

            hypervisor_access: least

            # The runner's own recipes.yaml, dumped verbatim.  Secrets are
            # written store: here, never secret: -- see L</SECRETS IN recipes>.
            recipes:
                _base:
                    _global:
                        install_dir: /opt/domains
                someguest.test.test:
                    nginx:
                        cert_password: "store:someguest/tls/password"

=head2 DESCRIPTION

A guest that can build guests.  It gets a perl new enough to load this
distribution, the CPAN modules that distribution declares, an
F</etc/trog-provisioner> of its own, and -- when asked for one -- a key a
hypervisor will let in.

The machine that I<runs> the provisioner is a guest like any other.
F<bin/setup_provisioner> is about the machine that I<hosts> what gets built,
which is a different machine and a different set of problems.

The checkout is optional (C<checkout: 0>) because a runner that manages its own
repositories -- a coding agent, say -- already has one, and a second copy under
C<install_dir> is a second copy to get out of step.  Point C<deps_from> at
whatever path it clones to instead and the dependencies still get installed.

=head3 What it needs from the guest, and how long it takes

Four vCPUs and 8GB, which is what this was measured on rather than what it was
tuned to -- see issue #123, which is about
measuring it properly -- the answer is probably "more, and the build should be
doing less".

A runner builds perl from source, installs the toolchain the C<perl> recipe
puts on top of it, and only then starts on C<Sys::Virt>, C<Dist::Zilla> and the
forty-odd distributions this one hands that recipe.  Most of the wall clock is
those distributions, and their own test suites when C<cpan_notest> is off.  On four vCPUs that does not fit the ninety minutes C<Trog::Guest>
allows a makefile and its whole postrun queue.

So build one with the budget raised:

    TROG_SETUP_TIMEOUT=3h bin/provision runner.example.test

Nothing breaks if you forget.  C<bin/provision> stops waiting and says so; the
queue carries on regardless, because F<scripts/post_install> is run by C<atd>
and not by anything on this end.  What you lose is the guest test result, which
is the thing you provisioned it to see.

=head3 SECRETS IN recipes

The C<recipes> argument is the runner's whole F<recipes.yaml>, and it is a trap
worth understanding before writing one.

C<bin/new_config> resolves every C<secret:> reference in the I<whole>
configuration before any recipe is constructed.  So a C<secret:> written inside
C<recipes> is resolved on the way in, and this recipe would be handed the
password itself -- which would then be dumped into the runner's
F<recipes.yaml>, into its C<data.tar.gz>, onto the guest and into every backup
taken of the domain, one level of indirection below anything that looks for
plaintext.

So write C<store:> instead.  Nothing resolves it, it arrives here as written,
and L</enrich> turns it back into C<secret:> on the way out -- leaving the
runner a F<recipes.yaml> full of references, exactly like a hand-written one.
The runner resolves them against its own store, which is what C<store> is for.

=head3 QUOTAS

A runner can build guests, and a guest costs disk, CPU and memory on somebody
else's machine.  Nothing in libvirt will hold it to a budget: there is no
accounting and no limit, and on the system URI every guest runs as
C<libvirt-qemu> whoever defined it, so there is no UID for a disk quota to
attach to either.

What does work is written in the hypervisor blocks above and enforced by the
kernel:

=over 4

=item * C<pool_path> and C<pool_name> together give the runner a storage pool
of its own.  Put that path on a filesystem with a limit on it -- C<zfs create
-o quota=500G tank/vm-disks/runner> -- and the limit is real.  Name both:
libvirt looks a pool up by name, so a path beside the name of a pool that
already exists elsewhere is ignored and every volume lands in the existing one.

=item * C<partition> puts every guest the runner builds into one systemd slice,
which the operator then caps once with C<systemctl set-property
machine-runner.slice CPUQuota=400%>.

Cap CPU and I/O there, not memory.  A C<MemoryMax> on a slice full of virtual
machines kills one rather than refusing the next, and the per-domain
equivalent is worse -- libvirt's own documentation warns that
C<< <memtune><hard_limit> >> gets guests OOM-killed.  What actually refuses a
guest for want of memory is C<reserve_memory> in F<hypervisors.conf>, which
already exists.

=back

Both are limits a cooperating runner respects.  Neither stops it naming a
different pool or partition: that takes libvirt's polkit access driver, which
is off by default, and which is a change to the hypervisor rather than to this
guest.  Say which of the two you have before telling anyone the runner is
capped.

=cut

my $ED25519_BITS = 256;

my $REPO = 'https://github.com/Troglodyne-Internet-Widgets/trog-provisioner.git';

=head3 required_recipes

perl, and what goes into it from CPAN, handed over as its C<cpan_deps>.  In this
order, and the order is the point:

=over 4

=item * B<Sys::Virt, pinned>, before anything resolves dependencies.  Left to a
dependency list, cpanm takes the newest, whose Makefile.PL wants a libvirt-dev
far newer than this guest has -- and says so forty minutes into the build, in a
message about pkg-config rather than about ordering.  Pinned to
C<libvirt_version> when one is named, and otherwise to what pkg-config says the
guest's libvirt is when the step runs, which is right whenever the runner and
the hypervisor are on the same distribution.

=item * B<What the checkout needs>, and what each of C<deps_from> needs, by
dzil.  Dist::Zilla itself comes with the perl, so nothing here asks for it.

=back

Worked out of what the dependency is handed, with this recipe's own schema
defaults laid under it -- C<checkout_dir> has one, and the closure is handed the
configuration raw.  The perl recipe validates what it is given.

=cut

sub required_recipes {
    my ($self) = @_;

    # perl is the whole of what a runner was missing: it builds
    # /opt/perl5/$version and gives it cpanm, Module::Build and Dist::Zilla.
    # Everything else here is CPAN or configuration.
    return (
        perl => sub {
            my %opts = ( Provisioner::Cookbook->defaults('trogrunner'), @_ );
            my $sys_virt =
              length( $opts{libvirt_version} // q{} )
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

sub args {
    return (
        type       => 'object',
        properties => {

            # Not required: Provisioner::Recipe::validate fills it in from
            # admin_user, and it does that after validation -- a required field
            # cannot be satisfied by something that runs later.
            user => { type => 'string' },

            checkout => { type => 'boolean', default => 1 },

            # Relative to install_dir/domain, and never the domain directory
            # itself: the service_user target creates that before the fragment
            # runs, and git clone refuses a target that is not empty.
            checkout_dir => { type => 'string', default => 'trog-provisioner' },

            # HTTPS rather than ssh: a guest that has just been built has no key
            # registered anywhere.
            repo_url    => { type => 'string', default => $REPO },
            repo_branch => { type => 'string', default => 'master' },

            # Which Sys::Virt to pin.  Empty means ask the guest what its
            # libvirt-dev is, which is right whenever the runner and the
            # hypervisor are on the same distribution.
            #
            # Deliberately not a number: this recipe must not load Trog::HV to
            # ask a hypervisor (see Provisioner::Recipe on why recipes do not),
            # so anything written here would be a guess that goes stale.
            libvirt_version => { type => 'string', default => q{} },

            # Absolute paths to install the dzil dependencies of, for a checkout
            # this recipe did not make.  Named by the operator rather than
            # worked out from another recipe: a runner that manages its own
            # repositories is the case this exists for, and only the person who
            # configured that knows where they land.
            deps_from => { type => 'array', items => { type => 'string' }, default => [] },

            # The runner's ipmap.cfg.  Defaults sit on the members rather than
            # on config itself, or a domain that sets one member would lose the
            # rest.
            config => {
                type       => 'object',
                default    => {},
                properties => {
                    basedir        => { type => 'string', default => '/opt/domains' },
                    admin_user     => { type => 'string' },
                    admin_email    => { type => 'string' },
                    admin_gecos    => { type => 'string', default => 'Administrator' },
                    admin_key      => { type => 'string', default => q{} },
                    gateway        => { type => 'string', default => q{} },
                    resolvers      => { type => 'string', default => '1.1.1.1, 8.8.8.8' },
                    dhcp_devname   => { type => 'string', default => 'ens3' },
                    bridge_devname => { type => 'string', default => 'ens4' },
                    ip             => { type => 'string', default => q{} },
                    transfer_user  => { type => 'string', default => q{} },
                    transfer_ip    => { type => 'string', default => q{} },
                    transfer_port  => { type => 'string', default => q{} },
                    addresses      => { type => 'string', default => q{} },
                    cidr           => { type => 'string', default => q{} },
                    nameservers    => { type => 'object', default => {}, additionalProperties => { type => 'string' } },
                    ips            => { type => 'object', default => {}, additionalProperties => { type => 'string' } },
                    aliases        => { type => 'object', default => {}, additionalProperties => { type => 'string' } },
                },
            },

            # Empty is a legitimate answer and means the runner is its own
            # hypervisor, which is what libvirt does when nothing says
            # otherwise.
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

            # A keepass database in this domain's data directory to install as
            # the runner's own.  Empty is fine: bin/preflight wants ipmap.cfg
            # and recipes.yaml, and nothing else.
            store => { type => 'string', default => q{} },

            hypervisor_access  => { type => 'string',  enum    => [qw{none least full}], default => 'none' },
            restrict_key_to_ip => { type => 'boolean', default => 1 },
        },
    );
}

=head3 formatters

C<yaml>, which dumps a structure and writes its C<store:> references back as
C<secret:> on the way out.  See L</SECRETS IN recipes> for why the indirection
exists.

=cut

sub formatters {
    return (
        yaml => Text::Xslate::html_builder( sub { return YAML::XS::Dump( _restore_refs( $_[0] ) ) } ),
    );
}

=head3 enrich

Fills the runner's identity in from the guest's, and works each hypervisor's URI
apart into the host, user and port an C<ssh-keyscan> needs.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    # The runner administers its guests as whoever administers this one, on the
    # same network, unless it was told otherwise.  All four come out of the
    # [global] block this guest was built from, so they are here.
    #
    # These are not decoration: bin/new_config refuses to generate anything
    # without admin_user, admin_key, admin_gecos, admin_email, gateway and
    # resolvers, so a runner that defaulted any of them to empty could not build
    # a single guest.  Measured on one, which is how the missing two were found.
    $opts{config}{admin_user}  //= $opts{admin_user};
    $opts{config}{admin_email} //= $opts{admin_email};

    foreach my $inherited (qw{admin_key gateway}) {
        $opts{config}{$inherited} = $opts{$inherited}
          unless length( $opts{config}{$inherited} // q{} );
    }

    # The schema defaults this to empty rather than leaving it absent, so an
    # empty string is what "nobody said" looks like here.
    $opts{config}{ip} = $opts{main_ip} unless length( $opts{config}{ip} // q{} );

    die "trogrunner: checkout_dir cannot be empty, and cannot be '.': git clone will not drop a repo into the domain directory, which already exists by then\n"
      if $opts{checkout} && ( !length( $opts{checkout_dir} // q{} ) || $opts{checkout_dir} eq '.' );

    # Both of these are written into a path under the domain directory, so an
    # absolute one silently means somewhere else entirely: `store:
    # /etc/trog-provisioner/secrets.kdbx` is the obvious thing to write and
    # renders as /opt/domains/<domain>//etc/..., which fails as a missing file
    # rather than as the mistake it is.
    _under_the_domain( $opts{checkout_dir}, 'checkout_dir' ) if $opts{checkout};
    _under_the_domain( $opts{store},        'store' )        if length( $opts{store} // q{} );

    foreach my $name ( sort keys %{ $opts{hypervisors} } ) {
        my $block = $opts{hypervisors}{$name};
        my $parts = _ssh_parts( $block->{libvirt_uri} )
          or die "trogrunner: could not read a host out of the libvirt_uri for hypervisor '$name': $block->{libvirt_uri}\n";

        # A remote hypervisor has to be reachable over ssh -- the runner needs
        # its filesystem as well as its libvirt, which is Trog::HV's rule and
        # not one worth discovering on the guest.
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
      if grep { $_ eq '..' } split( q{/}, $path );

    return 1;
}

# store:GROUP/TITLE/FIELD back to secret:GROUP/TITLE/FIELD, everywhere in the
# structure.  See SECRETS IN recipes: the indirection exists so that
# bin/new_config does not resolve these on the way in and dump the answers into
# a file that ends up in every backup of this domain.
sub _restore_refs {
    my ($node) = @_;

    return [ map { _restore_refs($_) } @$node ]                       if ref $node eq 'ARRAY';
    return { map { $_ => _restore_refs( $node->{$_} ) } keys %$node } if ref $node eq 'HASH';
    return $node                                                      if ref $node || !defined $node;

    return $node unless index( $node, 'store:' ) == 0;

    # The same test Trog::Secrets::needed makes of a secret: reference, and for
    # the same reason: a prefix, at the start, and nothing cleverer.
    return 'secret:' . substr( $node, length 'store:' );
}

# The ssh half of a libvirt connection URI.  URI knows nothing about the
# driver+transport scheme and hands back something with no authority accessors,
# so split it generically and re-parse the authority under a scheme it does
# understand -- the same trick, and for the same reason, as Trog::HV::_parse_uri.
sub _ssh_parts {
    my ($uri) = @_;
    return undef unless defined $uri && length $uri;

    my ( $scheme, $authority ) = URI::Split::uri_split($uri);
    return undef unless defined $scheme && length $scheme;

    my ( undef, $transport ) = split( quotemeta('+'), $scheme, 2 );
    my $server = ( defined $authority && length $authority ) ? URI->new("ssh://$authority") : undef;

    return {
        ssh  => ( defined $transport && $transport eq 'ssh' ) ? 1             : 0,
        host => $server                                       ? $server->host : undef,
        user => $server                                       ? $server->user : undef,
        port => $server                                       ? $server->port : undef,
    };
}

=head3 %grant = Provisioner::Recipe::trogrunner->grant($block)

What a domain's C<trogrunner> block asks for by way of hypervisor access:
C<access>, C<restrict> and C<hypervisors>.  An empty list when it asks for
none, which is the default and the usual answer.

Here rather than in F<bin/provision>, which is what acts on it, because the
defaults are in C<args()> and a second copy of them in a script is a second copy
to drift.  Reading them back out of the schema is what keeps there being one.

Takes the block as written rather than a validated one: this is asked of a
domain long after C<bin/new_config> ran, from a script that has a configuration
and no recipe object.

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
        'trogrunner.ipmap.cfg.tt'        => 'trogrunner.ipmap.cfg',
        'trogrunner.recipes.yaml.tt'     => 'trogrunner.recipes.yaml',
        'trogrunner.hypervisors.conf.tt' => 'trogrunner.hypervisors.conf',
        'trogrunner.profile.tt'          => 'trogrunner.profile',
    );
}

=head3 datadirs

The configuration directory, made before the fragment runs and owned the way
the rest of the domain is owned.

C<ips.db> is created in there the first time the runner assigns an address, and
it is the runner's memory of which guest holds what.  A root-owned directory
turns that into an unreadable SQLite error on the runner's first
C<bin/new_config>; being under C<install_dir> is what gets the database
salvaged onto the next rebuild.

=cut

# Relative to install_dir/domain, which is what datadirs takes -- the guest's
# /etc/trog-provisioner is a symlink to this, made by the fragment.
sub datadirs {
    return qw{etc/trog-provisioner};
}

=head3 guest_secrets

The key a hypervisor is asked to trust, kept in the secret store rather than in
the domain directory.

Declared whether or not C<hypervisor_access> was asked for, because this is a
class method and has no way to ask -- L</remote_files> has the same constraint.
That is not a hole: what the setting decides is whether C<bin/provision> writes
the public half into anybody's F<authorized_keys>, and a private key sitting
0600 on a guest no machine trusts opens nothing.

Keeping it in the store rather than making one per provision is what lets the
grant survive a rebuild: the same key comes back, and the line the hypervisor
already has still matches it.

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

# Provisioner::Utils::write_ssh_keypair, which is where the rewrap that makes
# these readable by both OpenSSH and CryptX lives -- see its POD.  ed25519 for
# the reason bin/preflight suggests it: short enough that an authorized_keys
# line stays readable.
sub _hypervisor_key {
    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $path = "$dir/id_ed25519";

    Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => $ED25519_BITS, 'trog-provisioner runner' );

    return ( File::Slurper::read_text($path) =~ s/\n\z//r );
}

=head3 remote_files

The configuration directory and the checkout, salvaged off the guest being
replaced.

What is worth having out of the first is C<ips.db>, which the runner made the
first time it assigned an address and which is the only record of which of its
guests holds what.  Losing it hands the next guest an address something already
has.

The directory rather than that one file: C<bin/new_config> fetches these with
C<get_dir>, so an entry here is a directory or it is an rsync that fails.

Both unconditionally: this is a class method and cannot see C<checkout>, and
salvaging a path that is not there has been quiet since the salvage gap was
closed.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;

    return (
        "$install_dir/$domain/etc/trog-provisioner/" => 'etc/trog-provisioner/',
        "$install_dir/$domain/trog-provisioner/"     => 'trog-provisioner/',
    );
}

=head3 remote_skip

The private key, and the runner's own secret store.  A secret salvaged off a
guest lands in the domain directory, and from there into C<data.tar.gz> and
into every backup taken of it; keeping them here is the whole of what
C<remote_skip> is for.

B<Not> the three configuration files, which are rendered afresh every
provision and so are stale on the guest by definition.  Two reasons, and the
second is the one that bites: the C<data> target unpacks the payload before any
recipe fragment runs, so the rendered copy is installed over the salvaged one
either way -- and a directory every file of which is skipped comes off the
guest empty, which is indistinguishable from a fetch that failed.  The
salvage-gap check refuses to rebuild over exactly that, so skipping them made
every second provision stop.

=cut

sub remote_skip {
    return qw{id_ed25519 secrets.kdbx};
}

sub tests {
    return qw{trogrunner.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves the checkout this recipe clones.  The host of the default only: C<fetch_hosts> is asked of the class,
without a configuration, so a C<repo_url> pointed somewhere else is not
declared here and goes straight upstream.

=cut

sub fetch_hosts {
    return qw{github.com};
}

1;
