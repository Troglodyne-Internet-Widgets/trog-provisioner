package Provisioner::Recipe::grubconf;

#ABSTRACT: Configure the grub kernel command line.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

Provisioner::Recipe::grubconf - set grub variables, such as the kernel command line.

=head1 SYNOPSIS

    grubconf:
        grub_vars:
            GRUB_CMDLINE_LINUX: "net.ifnames=0 ipv6.disable=1"

=head1 DESCRIPTION

Writes each key of C<grub_vars> as C<KEY="value"> to
F</etc/default/grub.d/99-grubconf.cfg>, then runs C<update-grub>.  Use it to
turn off things such as the new names for network adapters, or IPv6.

C<grub-mkconfig> reads only the files in F</etc/default/grub.d> whose names end
in F<.cfg>, in the order of their names.  The C<99> puts this file last, so a
value here wins over the same variable in F<50-cloudimg-settings.cfg>, which
the Ubuntu cloud image ships.

=cut

use parent qw{Provisioner::Recipe};

=head1 METHODS

=head2 args()

The schema of the options: C<grub_vars>, which is required, a map of at least
one variable name to a string.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{grub_vars}],
        properties => {
            grub_vars => {
                type                 => 'object',
                minProperties        => 1,
                additionalProperties => { type => 'string' },
                description          => 'The variables to set in /etc/default/grub.d/99-grubconf.cfg, by name.  Each value is written in double quotes.',
            },
        },
    );
}

=head2 template_files()

The one file of grub variables, which takes no list of recipes:
F<99-grubconf.cfg> from F<grubconf.tt>.

Returns a list of pairs, from the template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    my ($self) = @_;

    return (
        'grubconf.tt' => '99-grubconf.cfg',
    );
}

=head2 tests()

Returns a list of the test templates that run on the guest: F<grubconf.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{grubconf.tt};
}

1;
