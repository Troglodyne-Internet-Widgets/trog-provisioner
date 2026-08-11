package Provisioner::Recipe::adminconfig;

use 5.041;

use strict;
use warnings FATAL => 'all';

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
        type     => 'object',
        required => [qw{skel}],
        properties => {
            skel => { type => 'string' },
            pkgs => {
                type  => 'array',
                items => { type => 'string' },
            },
        },
    );
}

sub deps {
    my ( $self, %opts ) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return @{ $opts{pkgs} } if ref $opts{pkgs} eq 'ARRAY';
        return ();
    }
    die "Unsupported packager";
}

sub tests {
    return qw{adminconfig.tt};
}

1;
