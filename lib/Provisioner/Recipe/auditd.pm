package Provisioner::Recipe::auditd;

#ABSTRACT: Configure auditd rules to monitor the system.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::auditd - log changes to system files and domain files with auditd.

=head1 SYNOPSIS

In recipes.yaml:

    somedomain:
        auditd:

=head1 DESCRIPTION

This recipe configures auditd to log writes and attribute changes to these
places:

    * The directories that hold binaries and libraries
    * The home directories of root and the admin user
    * /etc and /var
    * The install_dir of each domain

TODO: send these logs to an intrusion detection system.

=cut

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
