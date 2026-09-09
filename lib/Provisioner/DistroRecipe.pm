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
user-data and meta-data, the setup script the guest runs, and the rsyslog
configuration that points its logs at the hypervisor.

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
        "$sub.rsyslog.conf.tt"   => 'rsyslog.conf',
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
