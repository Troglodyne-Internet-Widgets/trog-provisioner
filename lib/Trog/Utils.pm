package Trog::Utils;

use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use File::Slurper::Temp();

=head1 NAME

Trog::Utils - small things this installation does to files on disk

=head1 SYNOPSIS

    use Trog::Utils();

    Trog::Utils::write_pem( '/etc/ssl/private/thing.pem', $pem, 0600 );

=head1 DESCRIPTION

Helpers that belong to the machine rather than to provisioning: they take what
they are given and put it somewhere, and know nothing about recipes, guests or
domains.  L<Provisioner::Utils> is the other one, for the things that do.

=head1 SUBROUTINES

=head2 write_pem($path, $pem, $mode)

Write a PEM -- a certificate, a key, or several of them concatenated -- to
C<$path> and set its mode, dying if the mode cannot be set.

Through L<File::Slurper::Temp>, so nothing ever reads a half-written key: what
is incomplete is a temporary file, and the rename that puts it in place is
atomic.  The mode is applied to the file after that rename, so C<$path> holds
whatever mode the temporary was made with until the C<chmod> lands.

=cut

sub write_pem {
    my ( $path, $pem, $mode ) = @_;

    File::Slurper::Temp::write_binary( $path, $pem );
    chmod( $mode, $path ) or die "Could not set the mode of $path: $!\n";
    return;
}

1;
