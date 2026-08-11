package Provisioner::Recipe::nvm;

use 5.041;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nvm

=head2 SYNOPSIS

    somedomain:
        nvm:

    # Or with explicit user and nvm version:
    somedomain:
        nvm:
            user: someuser
            nvm_version: v0.40.3

=head2 DESCRIPTION

Installs L<nvm|https://nvm.sh> (Node Version Manager) for the configured user,
installs the latest LTS Node.js via C<nvm install node>, and appends
C<nvm use node> to the user's C<~/.bashrc> so that node is active in every
login shell.

Installation is idempotent  re-provisioning a host with nvm already installed
will update the nvm installation in place and leave the node version unchanged.

=head3 deps

Requires C<curl> to download the nvm install script.

=head3 validate

No required fields.  Optional:

=over 4

=item user

The system user for whom nvm will be installed.  Defaults to C<admin_user>
(the global admin user configured for the domain).

=item nvm_version

The nvm release tag to install (e.g. C<v0.40.3>).  Defaults to C<v0.40.3>.
Check L<https://github.com/nvm-sh/nvm/releases> for available versions.

=back

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{curl};
    }
    die "Unsupported packager";
}

sub args {
    return (
        properties => {
            user        => { type => 'string' },
            # TODO fetch latest version automatically
            nvm_version => { type => 'string', default => 'v0.40.3' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{user}        //= $opts{admin_user};
    return %opts;
}

sub tests {
    return qw{nvm.tt};
}

1;
