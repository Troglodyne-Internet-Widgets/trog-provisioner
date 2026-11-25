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

=head2 $class = $class->named($name)

The packager class for C<$name>, the answer of
L<Provisioner::DistroRecipe/packager>, such as C<deb>.  Dies naming C<$name>
when there is none.

=over 4

=item name - Str - the name of the packager

=back

Returns Str, the name of the class, which is loaded.  Dies when C<$name> is
empty, when it is not a name of the form of a packager, or when its class does
not load.

    my $packager = Provisioner::Packager->named('deb');    # 'Provisioner::Packager::Deb'

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

=head2 What every packager must say

Each of these is a class method, and the base class dies for each, naming the
packager that does not answer it.

=head3 @sources = $packager->merge(@sources)

The sources that recipes named, validated in the terms of this packager, with
one for each name.

=over 4

=item @sources - HashRef - each source that a recipe named in C<package_sources>

=back

Returns a list of HashRef, the sources.  Dies on a source that it cannot use,
and on two different sources under one name.

    my @merged = $packager->merge( map { $_->package_sources(%config) } @recipes );

=head3 @files = $packager->first_boot_files(%args)

The files that the guest must have before it installs its packages at first
boot, for the C<sources> and the C<conflicts> in C<%args>, for C<domain>.

=over 4

=item args - HASH - with C<domain>, the domain, Str, C<sources>, ArrayRef[HashRef], and C<conflicts>, ArrayRef[Str]

=back

Returns a list of HashRef, one file each, with C<path>, C<content>,
C<permissions>, and C<encoding>, which is C<b64> for content that is not text.
Dies when a source cannot be used, so the generation stops and not the guest.

    my @files = $packager->first_boot_files( domain => 'web.test.test', sources => \@sources, conflicts => ['sendmail'] );

=head3 @answers = $packager->answers(@answers)

The answers that the packages ask for at install, in the form that this
packager gives them.

=over 4

=item @answers - Str - each answer that a recipe gave in C<package_answers>

=back

Returns a list of Str, the answers.  A packager whose packages ask nothing
returns none.

    my @answers = $packager->answers(@package_answers);

=head3 @modules = $packager->cloud_init_modules()

The cloud-init modules that apply the sources and the answers, which a domain
added to a guest that is up runs again before its packages install.  Takes no
arguments.

Returns a list of Str, the names of the modules.

    my @modules = $packager->cloud_init_modules;

=head3 $pattern = $packager->package_name()

A regular expression, as a string, that matches a plain package name of this
packager and nothing else: no version, no archive, no file, no option and no
second name.  Something that installs whatever names it is given, such as the
installer of L<Provisioner::Recipe::clod>, refuses every other name with it.
Takes no arguments.

Returns Str, the pattern.

    my $pattern = $packager->package_name;
    die "not a package: $name\n" unless $name =~ m/\A(?:$pattern)\z/;

=head3 @argv = $packager->install_command()

The command, as a list of words, that installs the package names that follow
it from the archives that the guest trusts, with no prompt and no terminal.
It installs and does nothing else: it removes no package, and it installs no
package that is only recommended.  Takes no arguments.

Returns a list of Str, the words.

    my @argv = ( $packager->install_command, 'nginx' );

=head3 @argv = $packager->update_command($file)

The command, as a list of words, that refreshes the index of the one source
in C<$file>, a file of sources of this packager, and of no other source.

=over 4

=item file - Str - the path of the file of sources

=back

Returns a list of Str, the words.

    my @argv = $packager->update_command('/etc/apt/sources.list.d/vendor.sources');

=cut

# Dies, naming the packager $class and the $what that it does not answer.
my sub unanswered ( $class, $what ) {
    die( ( ref $class || $class ) . " does not say $what, which every packager must.\n" );
}

sub merge              { my ($class) = @_; return unanswered( $class, 'merge' ) }
sub first_boot_files   { my ($class) = @_; return unanswered( $class, 'first_boot_files' ) }
sub answers            { my ($class) = @_; return unanswered( $class, 'answers' ) }
sub cloud_init_modules { my ($class) = @_; return unanswered( $class, 'cloud_init_modules' ) }
sub package_name       { my ($class) = @_; return unanswered( $class, 'package_name' ) }
sub install_command    { my ($class) = @_; return unanswered( $class, 'install_command' ) }
sub update_command     { my ($class) = @_; return unanswered( $class, 'update_command' ) }

1;
