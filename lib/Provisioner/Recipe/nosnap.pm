package Provisioner::Recipe::nosnap;

#ABSTRACT: Remove snap from the system completely.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 Provisioner::Recipe::nosnap

=head2 SYNOPSIS

    somedomain:
        nosnap:

=head2 DESCRIPTION

Removes snap and every snap package from the system.  It also pins and holds
C<snapd> so that apt does not install it again.  Packages that require C<snapd>
then cannot install.

Use it if you consider snap an unacceptable risk on your deployed systems.

=cut

use parent qw{Provisioner::Recipe};

=head2 template_files()

The apt preferences file that pins C<snapd> so that apt does not install it.
It ignores the loaded recipes that the caller passes.

Returns a map from the template to the file that it renders, as a list of
pairs.

    my %files = $recipe->template_files();

=cut

sub template_files {
    my ($self) = @_;

    return (
        'nosnap.tt' => 'nosnap.pref',
    );
}

sub tests {
    return qw{nosnap.tt};
}

1;
