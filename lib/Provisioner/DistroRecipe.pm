package Provisioner::DistroRecipe;

#ABSTRACT: Base class for the recipe that says what a guest's distribution is.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Scalar::Util();

=head1 NAME

Provisioner::DistroRecipe - what a distribution has to answer for before a guest
can be built out of it.

=head1 SYNOPSIS

    package Provisioner::Recipe::ubuntu;
    use parent qw{Provisioner::DistroRecipe};

    sub packager   { return 'deb' }
    sub base_image { return 'https://cloud-images.ubuntu.com/noble/...' }
    sub packager_invocation { return 'DEBIAN_FRONTEND=... apt-get install ...' }

=head1 DESCRIPTION

A domain says which distribution it is built on in the C<distro> of its
C<_global>, and that names a recipe:

    _base:
        _global:
            distro: ubuntu

That recipe is this class.  It answers the questions the build has to have
settled before there is a guest at all -- which image to lay the disk over, which
packager the recipes are naming packages for, how to invoke it -- and it renders
the files a guest is built from: the network configuration, the cloud-init
user-data and meta-data, and the setup script the guest runs.

=head2 It is a recipe, in the ordinary way

Nothing here is a special interface for rendering.  The five files are declared
in C<template_files>, written as Xslate templates under
F<templates/E<lt>distroE<gt>/files/>, and rendered by C<render_file> like any
other recipe's generated files.  What is particular to a distribution is which
templates those are, which is why C<template_files> is keyed on
C<template_subdir> rather than written out.

=head2 It directs the build rather than running in it

C<is_module> is false, so C<bin/new_config> depsolves this recipe -- it is
configured, and things may depend on it -- and then leaves it out of the module
list.  There is no makefile fragment, because everything it does happens before
the guest exists to run a makefile.

Every distro recipe depends on L<Provisioner::Recipe::vm>, which is the other
half of the same division: this one describes what the guest runs, that one
describes the machine it runs on.

=head2 What a distribution has to say for itself

The methods below die in this class rather than defaulting.  A distribution that
has not answered one of them is not a distribution this can build, and saying so
is better than building a guest out of somebody else's answer.

=cut

=head1 METHODS A DISTRIBUTION MUST ANSWER

=head2 $packager = $distro->packager()

Which packaging system the recipes are naming packages for -- C<deb>, C<rpm>.

No recipe in this distribution branches on it any more: a recipe's packages live
in that distribution's subclass of it.  It is still handed to every recipe as
C<target_packager>, for the ones in a vendor C<libdir> that have not moved their
package names down yet -- see L<Provisioner::Recipe/Where the packages are named>
-- and for anything that has to describe the guest without loading a recipe.

=cut

sub packager { return shift->_unanswered('packager') }

=head2 $url = $distro->base_image()

The cloud image every guest's disk is layered over, as a URL the hypervisor can
fetch.

This is written into a domain's F<provision.conf> as C<image>, and
L<Trog::HV/base_image> is what downloads it.

=cut

sub base_image { return shift->_unanswered('base_image') }

=head2 $cmd = $distro->packager_invocation()

The command that installs a list of packages, non-interactively, without a
terminal to answer anything at.

=head2 $cmd = $distro->packager_up_invocation()

The command that upgrades what is installed.

=head2 $cmd = $distro->packager_remove_invocation()

The command that removes a list of packages.

All three end up in the generated makefile as C<packager_invocation> and
friends, which is why F<templates/makefile.tt> can stay distribution-neutral.

=cut

=head2 $url = $distro->current_image()

The image this distribution would have a guest built on today, or C<undef>.

C<base_image> is what guests are actually built on, and it is pinned on purpose:
a release moves and a fleet does not have to move with it.  This is the other
half of that -- what the distribution itself says is current, so that
C<bin/preflight> can point out a pin that has fallen a release behind.

B<Undef is a real answer> and the default one.  It means either that this
distribution has no way of being asked, or that it was asked and did not
answer -- a preflight run has no business failing because a mirror was down.
So a caller treats undef as "no opinion" and says nothing.

=cut

sub current_image { return undef }

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

False.  See L</It directs the build rather than running in it>.

=cut

sub is_module { return 0 }

=head2 %args = $distro->args()

What a distribution takes.

=over 4

=item * C<mirror> -- a package mirror for guests to prefer over the
distribution's own archive.  Empty by default, which is no mirror at all.

=item * C<mirror_insecure> -- whether to let apt install from a repository it
cannot verify.  B<Declares no default>, because the answer depends on C<mirror>:
C<enrich> turns it on when a mirror is configured and off when one is not, which
is what every guest has had.  A schema default cannot say "the same as whether
that other field is set".

=back

Set them in a domain's C<_global>, which every recipe is handed:

    _base:
        _global:
            mirror: aptmirror.example.com

B<Not> under a C<_base> block for the distro recipe itself.  Recipe blocks merge
with C<STORAGE_PRECEDENT> -- see L<Provisioner::Cookbook/domain_config> -- which
takes C<_base>'s side, so a value written there could never be overridden by a
domain that wanted a different one.  C<_global> merges the other way.  A single
domain's own C<< <domain>: <distro>: { mirror: ... } >> does work and beats both.

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
            mirror_insecure => {
                type        => 'boolean',
                description => 'Let apt install from a repository it cannot verify.  Defaults to on when a mirror is configured and off when one is not, which is what every guest has had.  Turn it off against a mirror that carries the archive own signed indices -- one built by the aptmirror recipe does, being a verbatim copy.',
            },
        },
    );
}

=head2 $path = $distro->mirror_path()

What this distribution appends to a mirror named as a bare domain, so that
C<aptmirror.example.com> becomes a URL a guest can fetch from.

Empty here.  A distribution that serves its archive under a path -- Ubuntu's
C</ubuntu> -- says so.

=cut

sub mirror_path { return q{} }

=head2 $uri = $distro->mirror_uri(%opts)

The mirror this guest should prefer, as a URL, or empty for none.

Two shapes, told apart by whether there is a scheme.  A URL is used as written,
which is how a mirror outside this installation is named.  Anything else is a
domain name and is resolved to that domain's address out of the ip pool, because
a guest runs cloud-init before it has DNS -- so a name is no use to it and the
address has to be baked in.

Dies on a name the pool has no address for.  Resolving it to nothing would
otherwise write C<http:///...> into the guest's apt configuration and fail at
first boot, a long way from the line that caused it.

Empty for a guest that is its own mirror.  The natural way to configure this is
one line in C<_base>'s C<_global>, which necessarily includes the mirror host --
and on the build that makes it, there is nothing there to fetch from yet.

=cut

sub mirror_uri {
    my ( $self, %opts ) = @_;

    my $mirror = $opts{mirror} // q{};
    return q{} unless length $mirror;

    # The scheme, rather than counting dots: aptmirror.example.com and
    # mirror.example.net are both dotted, and only one of them says how to get
    # there.
    return $mirror if $mirror =~ m{\A[a-z][a-z\d+.-]*://}i;

    my $domain = $opts{domain} // q{};
    if ( $domain eq $mirror ) {
        print "$domain is the mirror, so it is built from the archive rather than from itself.\n";
        return q{};
    }

    my $address = ( $opts{ipmap} // {} )->{$mirror};
    if ( !defined $address || !length $address ) {
        my $url = 'http://' . $mirror . $self->mirror_path;
        die <<"NOPE";
No address for '$mirror', which $domain is configured to use as its package mirror.
A bare name is resolved out of the ip pool, because a guest runs cloud-init before
it has DNS -- so it has to be a domain this installation assigns an address to.
A mirror anywhere else is named as a URL instead:

    mirror: $url
NOPE
    }

    return "http://$address" . $self->mirror_path;
}

=head2 %files = $distro->template_files()

The five files a guest is built from, as any other recipe declares its generated
files.

Keyed on C<template_subdir> rather than written out, so a distribution gets its
own set by being named -- F<templates/debian/files/debian.user-data.tt> and so
on -- rather than by overriding this.

They are written beside the domain and are deliberately B<not> part of the
payload: F<user-data> carries the private half of the guest's key, and
F<setup.sh> reaches the guest inside cloud-init's C<write_files> rather than in
the tarball it is the script for fetching.

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

Adds C<vm>, which every distro recipe depends on.

A guest is a distribution running on a machine, and those are two different
questions with two different sets of answers -- so they are two recipes, and
this is the one that says the second follows from the first.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    return ( $self->SUPER::required_recipes(%opts), vm => sub { return %opts } );
}

=head2 $dir = $distro->template_subdir()

The directory under F<templates/> holding this distribution's fragments and
generated files, which is the recipe's own name.

C<bin/new_config> puts it in front of F<templates/> on the search path, so a
distribution's version of a fragment wins over the generic one by being found
first.

=cut

sub template_subdir {
    my ($self) = @_;
    my $name = Scalar::Util::blessed($self) || $self;
    $name =~ s/\A.*:://;
    return $name;
}

1;
