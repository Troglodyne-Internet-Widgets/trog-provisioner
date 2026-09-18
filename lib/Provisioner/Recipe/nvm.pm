package Provisioner::Recipe::nvm;

#ABSTRACT: Install nvm and the latest node for the configured user.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nvm

=head2 SYNOPSIS

    somedomain:
        nvm:

    # Or with a user and an nvm version:
    somedomain:
        nvm:
            user: someuser
            nvm_version: v0.40.3

=head2 DESCRIPTION

Installs L<nvm|https://nvm.sh> (Node Version Manager) for the configured user.
Then it installs the latest Node.js with C<nvm install node> and makes it the
default alias.  It appends the nvm loader and C<nvm use node> to the
C<~/.bashrc> of the user, so node is active in every interactive shell.

The same C<~/.bashrc> exports C<NODE_PATH>.  It points at the global
C<node_modules> directory of the active node version.  It comes from
C<NVM_BIN>, so it follows a version switch.  Without it, C<require()> cannot
find a module installed with C<npm -g>.

You can run the recipe again on a host that has nvm.  The install script then
updates nvm in place.  C<nvm install node> installs a newer node only if one
was released.

=head3 deps

L<Provisioner::Recipe::Ubuntu::nvm> lists the packages.

=head3 args

No field is required.  Optional:

=over 4

=item user

The system user that gets nvm.  The default is C<admin_user>, the admin user
configured for the domain.

=item nvm_version

The nvm release tag to install.  The default is C<v0.40.3>.
L<https://github.com/nvm-sh/nvm/releases> lists the available versions.

=back

=cut

sub args {
    return (
        properties => {

            # TODO: fetch the latest version automatically
            nvm_version => { type => 'string', default => 'v0.40.3' },
        },
    );
}

sub tests {
    return qw{nvm.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

The host of the nvm installer, and the host that nvm gets node from.

Only this list names nodejs.org.  C<nvm install node> fetches from it, so no
template in this recipe contains that URL.

=cut

sub fetch_hosts {
    return qw{raw.githubusercontent.com nodejs.org};
}

1;
