package Provisioner::Recipe::auditd;

use 5.041;

use strict;
use warnings FATAL => 'all';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::auditd

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        auditd:

=head2 DESCRIPTION

Set up auditd to monitor various goings-on in the system.

In particular we set up rules to watch:

    * Every single binary on the system
    * Root and admin user homes
    * /etc and /var
    * TODO: watch dirs important to the various targets

TODO integrate this into some manner of IDS mechanism.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{auditd};
    }
    die "Unsupported packager";
}

sub template_files {
    my ($self) = @_;

    return (
        'auditd.global.tt' => 'global.rules',
        'auditd.domain.tt' => 'domain.rules',
    );
}

sub tests {
    return qw{auditd.tt};
}

1;
