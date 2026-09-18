package Provisioner::Recipe::claude;

#ABSTRACT: Install claude-code globally.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::claude

=head2 SYNOPSIS

    somedomain:
        claude:

=head2 DESCRIPTION

Install claude-code globally with C<npm>, if the guest has no C<claude> command.

The recipe also installs F<.claude/settings.json> in the directory of the
domain under C<install_dir>.  The settings enable the perl-slop plugin on every
guest.  They enable more plugins when the domain runs the C<perl> or C<perllsp>
recipe.  Each enabled plugin comes with the marketplace that publishes it.

The recipe salvages F<.claude.json> from that directory on the old guest.

SLOP in the ice machine.

=cut

sub template_files {
    return (
        'claude.settings.json.tt' => 'claude.settings.json',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude.json" => '.claude.json',
    );
}

sub tests {
    return qw{claude.tt};
}

1;
