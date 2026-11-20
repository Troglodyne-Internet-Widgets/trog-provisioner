package Provisioner::Recipe::Ubuntu::ossecagent;

#ABSTRACT: What the OSSEC agent needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::ossecagent};

use Provisioner::Cookbook();

=head1 NAME

Provisioner::Recipe::Ubuntu::ossecagent - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::ossecagent>.

=head1 DESCRIPTION

C<ossec-hids-agent> comes from the archive of Atomicorp, as the manager does.

=cut

sub deps {

    # libxml-libxml-perl for the ossec language of configd.
    return qw{ossec-hids-agent libxml-libxml-perl};
}

=head2 @sources = $recipe->package_sources()

The archive of the manager, from L<Provisioner::Recipe::Ubuntu::ossec>.

=cut

sub package_sources {
    my ( $self, %opts ) = @_;
    return Provisioner::Cookbook->load( 'ossec', distro => 'ubuntu' )->package_sources(%opts);
}

1;
