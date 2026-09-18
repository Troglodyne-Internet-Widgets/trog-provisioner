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
The C<[global]> section of F<ipmap.cfg> names that user as C<admin_user>.

C<pkgs> is optional.  It lists packages to install on the guest for the admin.

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

=head2 @pkgs = $recipe->deps(%opts)

Returns the C<pkgs> in C<%opts>, or nothing.  The operator names these
packages, so this generic recipe answers and no distro variant does.  See
C<deps> in L<Provisioner::Recipe>.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return @{ $opts{pkgs} } if ref $opts{pkgs} eq 'ARRAY';
    return ();
}

sub fetch_sources {
    my ( $self, %opts ) = @_;
    return defined $opts{skel} ? ( $opts{skel} ) : ();
}

sub tests {
    return qw{adminconfig.tt};
}

1;
