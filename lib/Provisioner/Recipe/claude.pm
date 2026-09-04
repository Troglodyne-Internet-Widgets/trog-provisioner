package Provisioner::Recipe::claude;

#ABSTRACT: Install claude-code globally.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

=head1 Provisioner::Recipe::claude

=head2 SYNOPSIS

    somedomain:
        claude:

=head2 DESCRIPTION

Install claude-code globally.

SLOP in the ice machine.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{nodejs npm};
    }
    die "Unsupported packager";
}

sub template_files {
    return (
        'claude.settings.json.tt' => 'claude.settings.json',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude.json"       => '.claude.json',
    );
}

sub tests {
    return qw{claude.tt};
}

1;
