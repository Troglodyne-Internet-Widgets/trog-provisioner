package Provisioner::Recipe::perl;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perl

=head2 SYNOPSIS

    somedomain:
        perl:

=head2 DESCRIPTION

Downloads the latest perl, compiles it and slams it into /opt/perl5/$version

Sets up a .bashrc in the install_dir which includes that perl's bindir in $PATH.

TODO: allow specification of version.

TODO: allow list of cpan deps

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{perlbrew libcarp-always-perl};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;
    my $user = $opts{user};
    die "Must set user in [perl] section of recipes.yaml" unless $user;

    return %opts;
}

sub tests {
    return qw{perl.tt};
}

1;
