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

TODO: send these logs to grafana (#219).

=head1 METHODS

=head2 template_files()

The two rule files of auditd, which are the same on every guest, so it takes
no list of recipes: F<global.rules> from F<auditd.global.tt>, and
F<domain.rules> from F<auditd.domain.tt>.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    my ($self) = @_;

    return (
        'auditd.global.tt' => 'global.rules',
        'auditd.domain.tt' => 'domain.rules',
    );
}

=head2 tests()

Returns a list of the test templates that run on the guest: F<auditd.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{auditd.tt};
}

1;
