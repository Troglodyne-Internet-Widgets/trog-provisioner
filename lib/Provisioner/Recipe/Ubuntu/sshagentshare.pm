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

sub deps {
    return qw{openssh-client};
}

1;
