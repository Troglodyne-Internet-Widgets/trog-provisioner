package Provisioner::Recipe::adminconfig;

#ABSTRACT: Set up the admin user's skel and packages.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

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

Set up the skel for the admin user specified in ipmap.cfg.

Optionally add in packages for the administrator to use on the provisioned host.

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

# The only deps() left in a generic recipe, and the only one that belongs in
# one: these package names are the operator's own, out of their configuration,
# rather than anything any distribution knows.  So there is nothing for a
# distro variant of this recipe to say, whichever distribution it is for -- and
# if the names an operator writes here turn out to need saying per
# distribution, that is a change to what pkgs means and not to where this
# lives.
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
