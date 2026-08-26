package Provisioner::Recipe::data;

#ABSTRACT: Schlep data from the hypervisor onto the guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::data

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        data:
           - from: /opt/domaindata/my.domain
             to: /opt/domains/my.domain
           - from: /foo/bar
             to: /baz

In ipmap.cfg:

    transfer_user=whoever_runs_trog_provisioner

=head2 DESCRIPTION

Schlep data from the hypervisor onto the guest.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openssh-server openssh-client rsync};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type => "object",
        required => [qw{from to}],
        parameters => {
            from => { type => "string" },
            to   => { type => "string" },
        },
    );
}

sub tests {
    return qw{data.tt};
}

1;
