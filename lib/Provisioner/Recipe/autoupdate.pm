package Provisioner::Recipe::autoupdate;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::autoupdate

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        autoupdate:
            autorestart: "/root/noautorestart"

=head2 DESCRIPTION

Automatically install updates from the package manager.

Optionally autorestart when this updates the kernel, unless the specified touchfile is present.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{};
    }
    die "Unsupported packager";
}

sub template_files {
    return (
        'autoupdate.cron.tt'  => 'autoupdate_cron',
        'autorestart.cron.tt' => 'autorestart_cron',
    );
}

1;
