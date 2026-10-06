package Provisioner::Vars;

#ABSTRACT: The numbers that more than one module uses, each named once.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Readonly;

=head1 NAME

Provisioner::Vars - the numbers that more than one module uses, each named once.

=head1 SYNOPSIS

    use Provisioner::Vars();

    my $disk = 40 * $Provisioner::Vars::GB;
    $? = $Provisioner::Vars::STATUS_EXIT_1;

=head1 DESCRIPTION

A number that two modules both write is a number that can disagree with
itself, and a reader has to work out what C<1024 * 1024 * 1024> or C<1 << 8>
means each time.  Each one is here once, as the value, under a name that says
what it is.

They are package variables made with C<Readonly::Scalar>: a variable
interpolates and can be searched for by its C<$>, and C<Readonly> refuses an
assignment, so that nothing changes a number that every module reads.  Nothing
exports them: write the whole name.

=head2 Bytes

C<$KB>, C<$MB>, C<$GB> and C<$TB> are powers of 1024, which is what libvirt,
qemu and the clouds mean by them.  Libvirt also reports memory in KiB, so
dividing by C<$KB> turns that into MB.

=head2 Wait statuses

What C<$?> holds after C<system> or a backtick when the child exited with a
code: the code shifted left eight bits.  C<0> is success and needs no name.
These are for faking a failure in a test, and for comparing against one.

=over 4

=item * C<$STATUS_EXIT_1>, a child that exited 1.

=item * C<$STATUS_EXIT_2>, a child that exited 2.

=item * C<$STATUS_NOT_FOUND>, a shell that exited 127 because it could not
find the command.

=back

=head2 Time

C<$HOURS_A_MONTH> is 730, which is how a cloud that bills by the hour states
a monthly price: 8760 hours in a year, over twelve.

C<$SECONDS_A_DAY> is 86 400, for a certificate's lifetime in days and a
timeout given in days.

=cut

Readonly::Scalar our $KB => 1_024;
Readonly::Scalar our $MB => 1_048_576;
Readonly::Scalar our $GB => 1_073_741_824;
Readonly::Scalar our $TB => 1_099_511_627_776;

Readonly::Scalar our $STATUS_EXIT_1    => 256;
Readonly::Scalar our $STATUS_EXIT_2    => 512;
Readonly::Scalar our $STATUS_NOT_FOUND => 32_512;

Readonly::Scalar our $HOURS_A_MONTH => 730;
Readonly::Scalar our $SECONDS_A_DAY => 86_400;

1;
