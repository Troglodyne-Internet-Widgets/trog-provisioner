package Provisioner::DistroRecipe;

#ABSTRACT: Base class for the recipe that names the distribution of a guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Packager();
use Provisioner::Utils();

use Scalar::Util();

=head1 NAME

Provisioner::DistroRecipe - what a distribution must supply before the
provisioner can build a guest from it.

=head1 SYNOPSIS

    package Provisioner::Recipe::ubuntu;
    use parent qw{Provisioner::DistroRecipe};

    sub packager   { return 'deb' }
    sub base_image { return 'https://cloud-images.ubuntu.com/noble/...' }
    sub packager_invocation { return 'DEBIAN_FRONTEND=... apt-get install ...' }

=head1 DESCRIPTION

A domain names its distribution in the C<distro> key of its C<_global>.  That
value names a recipe:

    _base:
        _global:
            distro: ubuntu

That recipe is a subclass of this class.  It answers the questions that the
build must settle before a guest exists:

=over 4

=item * Which image the disk of the guest goes on top of.

=item * Which packager the recipes name packages for.

=item * How to run that packager.

=back

It also renders the files that a guest is built from.  These are the network
configuration, the cloud-init user-data and meta-data, and the setup script that
the guest runs.

=head2 It is an ordinary recipe

This class has no special interface for rendering.  C<template_files> declares
the four files.  They are Xslate templates under
F<templates/E<lt>distroE<gt>/files/>, and C<render_file> renders them like the
generated files of any other recipe.  Only the choice of templates is particular
to a distribution.  That is why C<template_files> is keyed on
C<template_subdir> and is not a fixed list.

=head2 It directs the build and does not run in it

C<is_module> is false.  So C<bin/new_config> depsolves this recipe, which
configures it and lets other recipes depend on it.  Then it leaves the recipe
out of the module list.  The recipe has no makefile fragment, because all of its
work happens before the guest exists to run a makefile.

Every distro recipe depends on L<Provisioner::Recipe::vm>.  The two recipes
divide one job.  This one describes what the guest runs, and C<vm> describes the
machine that it runs on.

=head2 What a distribution must answer

The methods below die in this class and have no default.  If a distribution
does not answer one of them, the provisioner cannot build a guest from it.  An
error is better than a guest built from the answer of a different distribution.

=cut

=head1 METHODS A DISTRIBUTION MUST ANSWER

=head2 $packager = $distro->packager()

The packaging system that the recipes name packages for, for example C<deb> or
C<rpm>.  It also names the L<Provisioner::Packager> that turns the archives,
answers and conflicts of the recipes into what first boot needs.

No recipe in this checkout branches on it.  The packages of a recipe are in the
subclass of that recipe for each distribution.  Every recipe still gets this
value as C<target_packager>, for two kinds of reader:

=over 4

=item * A recipe in a vendor C<libdir> that still names its packages in the
parent class.  See L<Provisioner::Recipe/Where the packages are named>.

=item * Code that describes the guest without loading a recipe.

=back

=cut

sub packager { return shift->_unanswered('packager') }

=head2 @modules = $distro->rerun_modules()

The cloud-init modules that a domain added to a guest that is up runs again,
in order, from its own user-data.  The first ones point the downloads at the
fetch cache and write the files that the packager needs, then the packager
applies what it has to, and then the packages install and the accounts are
made.

=cut

sub rerun_modules {
    my ($self) = @_;
    return (
        qw{cc_bootcmd cc_write_files},
        Provisioner::Packager->named( $self->packager )->cloud_init_modules(),
        qw{cc_package_update_upgrade_install cc_users_groups},
    );
}

=head2 $url = $distro->base_image()

The cloud image that is the base layer of the disk of every guest.  It is a URL
that the hypervisor can fetch.

It is what a libvirt hypervisor builds from: L<Trog::HV::Libvirt/image_for_distro>
answers with it, C<bin/new_config> writes it into the F<provision.conf> of a
domain as C<image>, and C<base_image> in L<Trog::HV::Libvirt> downloads it.  A
cloud has its own catalog, and names its image from C<distribution> and
C<release_version> instead.

=cut

sub base_image { return shift->_unanswered('base_image') }

=head2 $version = $distro->release_version()

The version of the release that this distribution pins, as image catalogs name
it: C<24.04>, not C<noble>.  A cloud finds the image a guest boots from by it,
with C<distribution>: Linode as C<linode/ubuntu24.04>, Glance by its
C<os_distro> and C<os_version> properties.

=cut

sub release_version { return shift->_unanswered('release_version') }

=head2 $name = $distro->distribution()

The distribution, as image catalogs name it: Glance's C<os_distro>, and the
start of the name of a Linode image.  The name of the recipe, which is what the
catalogs call every distribution that this toolkit has a recipe for.  A
distribution whose catalog name is not its recipe name overrides it.

=cut

sub distribution { my ($self) = @_; return $self->recipe_name }

=head2 $cmd = $distro->packager_invocation()

The command that installs a list of packages.  It runs without prompts, and it
does not need a terminal.

=head2 $cmd = $distro->packager_up_invocation()

The command that upgrades the installed packages.

=head2 $cmd = $distro->packager_remove_invocation()

The command that removes a list of packages.

C<bin/new_config> puts all three into the generated makefile under the same
names.  So F<templates/makefile.tt> does not depend on a distribution.

=cut

sub packager_invocation        { return shift->_unanswered('packager_invocation') }
sub packager_up_invocation     { return shift->_unanswered('packager_up_invocation') }
sub packager_remove_invocation { return shift->_unanswered('packager_remove_invocation') }

sub _unanswered {
    my ( $self, $what ) = @_;

    my $distro = Scalar::Util::blessed($self) || $self;
    $distro =~ s/\AProvisioner::Recipe:://;

    die "The $distro distro recipe does not say what its $what is.\n" . "Every distribution has to answer that before a guest can be built on it;\n" . "see perldoc Provisioner::DistroRecipe.\n";
}

=head1 METHODS

=head2 $bool = $distro->is_module()

False.  See L</It directs the build and does not run in it>.

=cut

sub is_module { return 0 }

=head2 $url = $distro->current_image()

The image that this distribution names as current today, or C<undef>.

C<base_image> is the image that guests are built on, and it is pinned on
purpose.  A new release does not force the fleet to move.  C<bin/preflight>
compares the two and reports a pin that is a release behind.

C<undef> is a valid answer and the default.  It means that this distribution
has no way to be asked, or that it did not answer.  A preflight run must not
fail because a mirror is down.  So a caller treats C<undef> as "no opinion" and
reports nothing.

=cut

sub current_image { return undef }

=head2 %args = $distro->args()

Returns the schema of what a distribution takes.  C<bin/recipes ubuntu> prints
it with the full description of each field.  The fields that an operator sets
are these:

=over 4

=item * C<mirror>: a package mirror that guests use before the archive of the
distribution.  The default is empty, which means no mirror.  See C<mirror_uri>.

=item * C<cache>: a fetch cache that guests provision through.  The default is
empty, which means that every download goes to the upstream host.  See
C<cache_address> and L<Provisioner::Recipe::fetchcache>.

=item * C<mirror_insecure>: whether apt can install from a repository that it
cannot verify.  This field has no default, because the answer depends on
C<mirror>.  C<enrich> in the distribution subclass sets it on when a mirror is
configured and off when not.  A schema default cannot express that.

=back

Set them in the C<_global> of a domain, which every recipe gets:

    _base:
        _global:
            mirror: aptmirror.example.test

Use C<_global> and not a C<_base> block for the distro recipe.  A mirror is a
fact about the guest that several recipes get, and the distro recipe does not
own it.  Both places work, and a domain overrides what C<_base> says in either.
See L<Provisioner::Cookbook/domain_config>.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            mirror => {
                type        => 'string',
                default     => q{},
                description =>
                  'A package mirror for guests to prefer over the distribution archive.  Empty, the default, means no mirror: a guest uses whatever the image ships with.  A URL is used as written.  A bare domain name is resolved to that domain static IP out of the ip pool, with this distribution mirror_path appended, because a guest runs cloud-init before it has DNS.  The archive stays behind whichever you give, so a mirror that is behind, incomplete or down costs a fallback rather than a build.',
            },
            cache => {
                type        => 'string',
                default     => q{},
                description =>
                  'A fetch cache for guests to provision through: a guest built by the fetchcache recipe, named by its domain -- resolved out of the ip pool -- or by its IPv4 address.  Empty, the default, means none, and every download goes straight upstream.  For the length of a build, each host its recipes name in fetch_hosts is pointed at the cache, and only if the cache answers for that host when the build starts, so a cache that is down costs a build nothing.',
            },
            mirror_insecure => {
                type        => 'boolean',
                description => 'Let apt install from a repository it cannot verify.  Defaults to on when a mirror is configured and off when one is not, which is what every guest has had.  Turn it off against a mirror that carries the archive own signed indices -- one built by the aptmirror recipe does, being a verbatim copy.',
            },

            # bin/new_config computes these for the first boot of the guest, and
            # this recipe writes them into the seed.  They are readOnly because
            # no operator sets them.
            packages          => { type => 'array', items => { type => 'string' }, readOnly => 1, description => 'Every package the domain recipes asked for, installed before the makefile runs.' },
            package_sources   => { type => 'array', items => { type => 'object' }, readOnly => 1, description => 'The vendor archives that the domain recipes name, in the terms of the packager, which gives the guest them before its packages install.' },
            package_answers   => { type => 'array', items => { type => 'string' }, readOnly => 1, description => 'Answers for the questions the packages ask as they install, in the terms of the packager, given before they do.' },
            package_conflicts => { type => 'array', items => { type => 'string' }, readOnly => 1, description => 'Packages that the domain recipes conflict with, which the packager keeps off the guest.' },
            fetch_cache       => {
                type        => 'object',
                readOnly    => 1,
                description => 'The fetch cache that first boot installs through: its address, the certificate of its authority, the hosts to point at it, and scripts/fetch_via_cache.  Absent when there is no cache.',
                required    => [qw{address authority hosts script}],
                properties  => {
                    address   => { type => 'string' },
                    authority => { type => 'string' },
                    hosts     => { type => 'array', items => { type => 'string' } },
                    script    => { type => 'string' },
                },
            },
            ips           => { type => 'array',   items    => { type => 'string' }, readOnly    => 1, description => "The guest's addresses, out of the ip pool, written into its network configuration." },
            contact_email => { type => 'string',  nullable => 1,                    readOnly    => 1, description => "Who to mail about this guest, out of the installation admin_email, or nothing.  The seed refuses to be written without one rather than leaving root's mail undeliverable." },
            payload_dir   => { type => 'string',  readOnly => 1,                    description => 'Where on this machine the payload the guest fetches was built.' },
            dryrun        => { type => 'boolean', readOnly => 1,                    description => 'Whether this run is only writing configuration, so the seed names nothing it would have to create.' },

            # The network configuration of the guest matches its interfaces by MAC,
            # because the kernel can choose any device name.  The hypervisor
            # derives both MACs from the domain name.  Provisioner::Recipe::vm
            # puts the same pair into the XML.
            nat_mac    => { type => 'string', readOnly => 1, description => "MAC of the guest's NAT interface." },
            bridge_mac => { type => 'string', readOnly => 1, description => "MAC of the guest's bridged interface." },
        },
    );
}

=head2 %defaults = $distro->global_defaults()

Returns each default that C<args> declares, as a hash of field name to default.
Callable on the class.

The provisioner reads these settings from C<_global>, and every recipe gets
C<_global> as it is.  The schema defaults apply only when this recipe is
validated.  So without this method, an unset field reaches every other recipe as
absent.  C<bin/new_config> puts these defaults under C<_global>, so the schema
holds the only copy of each default.

A field with no default, such as C<mirror_insecure>, is left out.  Its absence
is the answer.

=cut

sub global_defaults {
    my ($class) = @_;

    my %args       = $class->args();
    my $properties = $args{properties} // {};
    return map { $_ => $properties->{$_}{default} } grep { exists $properties->{$_}{default} } sort keys %$properties;
}

=head2 $path = $distro->mirror_path()

The path that this distribution appends to a mirror named as a bare domain.  It
makes C<aptmirror.example.test> into a URL that a guest can fetch from.

Empty here.  A distribution that serves its archive under a path overrides it,
for example C</ubuntu> for Ubuntu.

=cut

sub mirror_path { return q{} }

=head2 $uri = $distro->mirror_uri(%opts)

Takes C<mirror>, C<domain> and C<ipmap> (domain name to address).  Returns the
mirror that this guest uses first, as a URL, or empty for none.

The value of C<mirror> has two forms.  If it has a scheme, it is a URL and is
used as written.  Use a URL for a mirror outside this installation.  Any other
value is a domain name.  This method resolves it to the address of that domain
from the ip pool.  A guest runs cloud-init before it has DNS, so a name is of no
use to it.

Dies on a name that has no address in the pool.  Without the error, the apt
configuration of the guest gets C<http:///...> and fails at first boot.

Returns empty when C<domain> is the mirror itself.  The usual configuration is
one line in the C<_global> of C<_base>, which includes the mirror host.  When
that host is built, it has nothing to fetch from yet.

=cut

sub mirror_uri {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain} // q{};
    my ( $kind, $value ) = Provisioner::Utils::fleet_address( $opts{mirror}, domain => $domain, ipmap => $opts{ipmap} );

    return q{}                                  if $kind eq 'none';
    return $value                               if $kind eq 'url';
    return "http://$value" . $self->mirror_path if $kind eq 'address';

    if ( $kind eq 'self' ) {
        print "$domain is the mirror, so it is built from the archive rather than from itself.\n";
        return q{};
    }

    my $url = 'http://' . $value . $self->mirror_path;
    die <<"NOPE";
No address for '$value', which $domain is configured to use as its package mirror.
A bare name is resolved out of the ip pool, because a guest runs cloud-init before
it has DNS -- so it has to be a domain this installation assigns an address to.
A mirror anywhere else is named as a URL instead:

    mirror: $url
NOPE
}

=head2 $address = $distro->cache_address(%opts)

Takes C<cache>, C<domain> and C<ipmap>.  Returns the address of the fetch cache
that this guest provisions through, or empty for none.

An IPv4 address in C<cache> is returned as it is.  A domain name is resolved to
its address from the ip pool.  Any other value dies, a URL too.  The guest writes
this value into F</etc/hosts> for the hosts that it downloads from, so it must be
an address.

Returns empty when C<domain> is the cache itself.  That guest fetches from the
upstream hosts, because the cache is empty when it is built.

C<bin/new_config> calls this one time and gives the result to every recipe as
C<cache_ip>.

=cut

sub cache_address {
    my ( $self, %opts ) = @_;

    my $domain = $opts{domain} // q{};
    my $cache  = $opts{cache}  // q{};
    return $cache if $cache =~ m/\A(?:\d{1,3}\.){3}\d{1,3}\z/;

    my ( $kind, $value ) = Provisioner::Utils::fleet_address( $cache, domain => $domain, ipmap => $opts{ipmap} );
    return q{}    if $kind eq 'none';
    return $value if $kind eq 'address';

    if ( $kind eq 'self' ) {
        print "$domain is the fetch cache, so it fetches from upstream rather than from itself.\n";
        return q{};
    }

    die <<"NOPE";
No address for '$cache', which $domain is configured to use as its fetch cache.
A guest points the hosts it downloads from at the cache by address, so name it
by a domain this installation assigns an address to, or by its IPv4 address.
NOPE
}

=head2 %files = $distro->template_files()

Returns the four files that a guest is built from, as template name to output
name.  Any other recipe declares its generated files the same way.

The template names start with C<template_subdir>.  So a distribution gets its
own set from its name, for example F<templates/debian/files/debian.user-data.tt>.
It does not override this method.

These files go beside the domain, and on purpose they are not part of the
payload.  F<user-data> holds the private key of the guest.  F<setup.sh> gets to
the guest in the C<write_files> of cloud-init, because it is the script that
fetches the payload tarball.

=cut

sub template_files {
    my ($self) = @_;
    my $sub = $self->template_subdir;

    return (
        "$sub.network-config.tt" => 'network-config',
        "$sub.meta-data.tt"      => 'meta-data',
        "$sub.setup.sh.tt"       => 'setup.sh',
        "$sub.user-data.tt"      => 'user-data',
    );
}

=head2 %required = $distro->required_recipes(%opts)

Returns what the parent class returns, with C<vm> added.  C<vm> gets the same
C<%opts>.

A guest is a distribution that runs on a machine.  Those are two questions with
different answers, so they are two recipes.  This method makes the second
follow from the first.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    return ( $self->SUPER::required_recipes(%opts), vm => sub { return %opts } );
}

=head2 $dir = $distro->template_subdir()

The directory under F<templates/> that holds the fragments and generated files
of this distribution.  It is the name of the recipe.  Callable on the class.

L<Provisioner::Cookbook/template_dirs> puts the directory of this name before
F<templates/> on the search path.  So the distribution version of a fragment
wins over the generic one.

=cut

sub template_subdir {
    my ($self) = @_;
    my $name = Scalar::Util::blessed($self) || $self;
    $name =~ s/\A\N*:://;
    return $name;
}

1;
