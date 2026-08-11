package Provisioner::Utils;

use 5.041;

use strict;
use warnings;

use List::Util qw{any};

# Helpers used across various modules

=head2 DESCRIPTION

Provisioner::Recipe helpers.

=cut

=head2 SUBROUTINES

=head3 already_required($module)

Avoid double-require sub redefs.

Returns BOOLEAN.

=cut

sub already_required {
    my $module = shift;
    my @available = keys(%INC);
    return 1 if any { m/\Q$module\E/ } @available;
    return 0;
}

=head3 lastuniq(@array)

List::Util::uniq, but with the last occurrence's order preserved instead of the first.

Returns ARRAY.

=cut

sub lastuniq {
    my @input = @_;
    my %hashed;
    @hashed{@input} = 0..@input;
    my @out;
    for my $idx (sort { $a <=> $b } values(%hashed)) {
        push(@out, $input[$idx]);
    }
    return @out;
}

1;
