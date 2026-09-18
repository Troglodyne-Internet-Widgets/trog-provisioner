package Trog::Config;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

Trog::Config - where this installation keeps its configuration

=head1 SYNOPSIS

    use Trog::Config();

    my $ipmap = Trog::Config->path('ipmap.cfg');
    my $fleet = Trog::Config->path('hypervisors.conf');

=head1 DESCRIPTION

The configuration of this installation is in F</etc/trog-provisioner>, and this
module is the one place that says so.

These files describe an installation, not this software.  They say which
machines exist, what addresses they have, and which hypervisors can hold them.
They also hold the passwords for all of it.  Because they are outside the
checkout, a commit to the public repository does not include them.  A command
also finds them from any directory.

Set C<TROG_PROVISIONER_CONFIG> to use a different directory.  Examples are
another installation, or a temporary directory for a test that must not read
the real one.

=head1 CLASS METHODS

=cut

our $DIR = $ENV{TROG_PROVISIONER_CONFIG} // '/etc/trog-provisioner';

=head2 dir

Returns the configuration directory.  C<TROG_PROVISIONER_CONFIG> overrides it
at each call.

=cut

sub dir { return $ENV{TROG_PROVISIONER_CONFIG} // $DIR }

=head2 path($name)

Returns the path of the file C<$name> in the configuration directory.  It does
not look for the file.

=cut

sub path {
    my ( $class, $name ) = @_;
    return $class->dir . "/$name";
}

=head1 SEE ALSO

L<Trog::Hypervisors>

=cut

1;
