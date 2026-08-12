package Provisioner::Recipe::perl;

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perl

=head2 SYNOPSIS

    somedomain:
        perl:

=head2 DESCRIPTION

Downloads the latest perl, compiles it and slams it into /opt/perl5/$version

Sets up a .bashrc in the install_dir which includes that perl's bindir in $PATH.

TODO: allow specification of version.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{perlbrew libcarp-always-perl};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        required   => [qw{user}],
        properties => {
            user => { type => 'string' },
        },
    );
}

sub tests {
    return qw{perl.tt};
}

1;
