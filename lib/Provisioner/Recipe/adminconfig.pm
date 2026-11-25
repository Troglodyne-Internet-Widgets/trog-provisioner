package Provisioner::Recipe::adminconfig;

#ABSTRACT: Set up the admin user's skel and packages.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::adminconfig

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        adminconfig:
            pkgs:
                - vim
                - tig
                - tmux
                - plocate
            skel: "/opt/dotfiles/foobar"

=head2 DESCRIPTION

Copies the C<skel> directory from this machine into the home of the admin user.
The C<_global> of the installation names that user as C<admin_user>.

C<pkgs> is optional.  It lists packages to install on the guest for the admin.

=head1 METHODS

=head2 args()

The schema of the options: C<skel>, a string, which is required, and C<pkgs>,
a list of strings.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{skel}],
        properties => {
            skel => { type => 'string' },
            pkgs => {
                type  => 'array',
                items => { type => 'string' },
            },
        },
    );
}

=head2 $recipe->deps(%opts)

Returns the C<pkgs> in C<%opts>, or nothing.  The operator names these
packages, so this generic recipe answers and no distro variant does.  See
C<deps> in L<Provisioner::Recipe>.

    my @pkgs = $recipe->deps( pkgs => [qw{vim tmux}] );

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return @{ $opts{pkgs} } if ref $opts{pkgs} eq 'ARRAY';
    return ();
}

=head2 $recipe->fetch_sources(%opts)

The C<skel> directory of this machine, which the guest fetches as the rsync
module C<skel>.  C<%opts> are the raw options of the recipe.

Returns the pair C<skel> and the path, or nothing when C<skel> is not set.

    my %paths = $recipe->fetch_sources( skel => '/opt/dotfiles/admin' );

=cut

sub fetch_sources {
    my ( $self, %opts ) = @_;
    return defined $opts{skel} ? ( skel => $opts{skel} ) : ();
}

=head2 tests()

Returns a list of the test templates that run on the guest:
F<adminconfig.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{adminconfig.tt};
}

1;
