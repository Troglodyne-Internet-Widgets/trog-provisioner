package Provisioner::Recipe::Ubuntu::sshagentshare;

#ABSTRACT: What sshagentshare needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::sshagentshare};

=head1 NAME

Provisioner::Recipe::Ubuntu::sshagentshare - Ubuntu's C<deps> for L<Provisioner::Recipe::sshagentshare>.

=cut

=head2 @pkgs = $recipe->deps()

C<openssh-client>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

sub deps {
    return qw{openssh-client};
}

1;
