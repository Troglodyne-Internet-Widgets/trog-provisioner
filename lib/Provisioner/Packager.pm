package Provisioner::Packager;

#ABSTRACT: What a family of distributions does with the packages that recipes name.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

Provisioner::Packager - What a family of distributions does with the packages
that recipes name.

=head1 SYNOPSIS

    my $packager = Provisioner::Packager->named( $distro->packager );
    my @files    = $packager->first_boot_files( domain => $fqdn, sources => \@sources, conflicts => \@conflicts );

=head1 DESCRIPTION

A recipe names its packages in C<deps>, the archives that they come from in
C<package_sources>, the answers that they ask for at install in
C<package_answers>, and what must stay off the guest in C<dep_conflicts>.  See
L<Provisioner::Recipe>.  How a guest gets any of that is a fact about its
family of distributions, not about the recipe and not about the generator.
Ubuntu and Debian share one answer, and the distributions of Red Hat share
another.

A packager is that answer.  L<Provisioner::DistroRecipe/packager> names it, and
the distro recipe asks it for what first boot needs.  Nothing else does, so
F<bin/new_config> and F<bin/provision> do not know which one it is.

A source is in the terms of its packager, because the terms of one family do
not map onto another: an apt archive has suites and components, and a C<dnf>
repository has a base URL with variables in it.  The distro subclasses of the
recipes write them, beside C<deps>.

=head1 METHODS

=head2 $class = Provisioner::Packager->named($name)

The packager class for C<$name>, the answer of
L<Provisioner::DistroRecipe/packager>, such as C<deb>.  Dies naming C<$name>
when there is none.

=cut

sub named {
    my ( $class, $name ) = @_;
    $name //= q{};
    die "No packager named for this distribution\n" if $name eq q{};
    die "'$name' is not the name of a packager\n" unless $name =~ m/\A[[:lower:]][[:lower:][:digit:]]*\z/;

    my $packager = __PACKAGE__ . '::' . ucfirst $name;
    eval { require "Provisioner/Packager/\u$name.pm"; 1 }    ## no critic (Modules::RequireBarewordIncludes) -- the name is the answer of a distro recipe
      or die "There is no packager for '$name': $packager does not load.\n$@";
    return $packager;
}

=head2 What a packager answers

Each of these is a class method, and the base class dies for each, naming the
packager that does not answer it.

=over 4

=item C<@sources = $packager-E<gt>merge(@sources)>

The sources that recipes named, validated in the terms of this packager, with
one for each name.  Dies on a source that it cannot use, and on two different
sources under one name.

=item C<@files = $packager-E<gt>first_boot_files(%args)>

The files that the guest must have before it installs its packages at first
boot, for the C<sources> and the C<conflicts> in C<%args>, for C<domain>.  Each
file is a hash reference with C<path>, C<content>, C<permissions>, and
C<encoding>, which is C<b64> for content that is not text.  Dies when a source
cannot be used, so the generation stops and not the guest.

=item C<@answers = $packager-E<gt>answers(@answers)>

The answers that the packages ask for at install, in the form that this
packager gives them.  A packager whose packages ask nothing returns none.

=item C<@modules = $packager-E<gt>cloud_init_modules()>

The cloud-init modules that apply the sources and the answers, which a domain
added to a guest that is up runs again before its packages install.

=back

=cut

sub merge              { my ($class) = @_; return $class->_unanswered('merge') }
sub first_boot_files   { my ($class) = @_; return $class->_unanswered('first_boot_files') }
sub answers            { my ($class) = @_; return $class->_unanswered('answers') }
sub cloud_init_modules { my ($class) = @_; return $class->_unanswered('cloud_init_modules') }

sub _unanswered {
    my ( $class, $what ) = @_;
    die( ( ref $class || $class ) . " does not say $what, which every packager must.\n" );
}

1;
