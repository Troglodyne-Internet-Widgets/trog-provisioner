use strict;
use warnings;

package Provisioner::Utils;

use List::Util qw{any};

# Helpers used across various modules

sub already_required {
    my $module = shift;
    my @available = keys(%INC);
    return 1 if any { m/\Q$module\E/ } @available;
    return 0;
}

# Unlike List::Util::uniq, we want the last occurrence's order preserved.
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
