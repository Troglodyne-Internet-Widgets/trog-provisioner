package Trog::Config;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';
=head1 NAME

Trog::Config - where this installation keeps its configuration

=head1 SYNOPSIS

    use Trog::Config();

    my $ipmap = Trog::Config->path('ipmap.cfg');
    my $fleet = Trog::Config->path('hypervisors.conf');

=head1 DESCRIPTION

F</etc/trog-provisioner>, and one place that says so.

These files describe an installation, not this software: which machines exist,
what addresses they have, which hypervisors there are to put them on, and the
passwords for all of it.  They lived in the checkout, which meant the
F<.gitignore> was the only thing standing between a password database and a
public repository, and meant every command had to be run from one particular
directory to find them.

Set C<TROG_PROVISIONER_CONFIG> to point somewhere else -- another installation,
or a temporary directory in a test that has no business reading the real one.

=head1 CLASS METHODS

=head2 dir

The configuration directory.

=head2 path($name)

One file inside it.

=cut

our $DIR = $ENV{TROG_PROVISIONER_CONFIG} // '/etc/trog-provisioner';

sub dir { return $ENV{TROG_PROVISIONER_CONFIG} // $DIR }

sub path {
    my ($class, $name) = @_;
    return $class->dir . "/$name";
}

=head1 SEE ALSO

L<Trog::Hypervisors>

=cut

1;
