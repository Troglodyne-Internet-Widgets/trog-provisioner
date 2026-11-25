package Provisioner::Recipe::Ubuntu::auditd;

#ABSTRACT: What auditd needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::auditd};

=head1 NAME

Provisioner::Recipe::Ubuntu::auditd - Ubuntu's C<deps> for L<Provisioner::Recipe::auditd>.

=cut

=head2 @pkgs = $recipe->deps()

C<auditd>, the audit daemon.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{auditd};
}

1;
