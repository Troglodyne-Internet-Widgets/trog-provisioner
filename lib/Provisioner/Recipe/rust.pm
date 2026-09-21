package Provisioner::Recipe::rust;

#ABSTRACT: Install a rust toolchain with rustup.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::rust

=head2 SYNOPSIS

    somedomain:
        rust:

    # Or naming the toolchain:
    somedomain:
        rust:
            toolchain: "1.83.0"

=head2 DESCRIPTION

C<rustup> comes from the distribution, and the toolchain comes from rustup.
The package is only the installer: it puts F</usr/bin/rustup> on the guest and
nothing to compile with, so the fragment asks it for a toolchain as well.

That is the global half, because a toolchain is a fact about the machine rather
than about a domain.  It installs for the account the makefile runs as, which
is root.

=head2 WHO GETS IT

Root, and only root.  rustup keeps a toolchain under C<RUSTUP_HOME>, which
defaults to F<$HOME/.rustup>, and puts the shims in C<CARGO_HOME>, which
defaults to F<$HOME/.cargo>.  So a service user that runs C<cargo> finds
nothing, however installed the toolchain is for root.

That is enough for a guest whose rust is built during the provision, which the
makefile runs as root.  A guest whose I<service> compiles rust wants the
toolchain somewhere both accounts read, and this recipe does not do that yet.

=head3 deps

L<Provisioner::Recipe::Ubuntu::rust> lists the packages.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            toolchain => {
                type        => 'string',
                default     => 'stable',
                description => 'What rustup installs and makes the default, as rustup names one: a channel such as stable or nightly, or a version such as 1.83.0.',
            },
        },
    );
}

sub tests {
    return qw{rust.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

C<static.rust-lang.org>, which rustup downloads a toolchain from.  No template
here holds that URL: rustup knows it, and this is the only thing that says so.

=cut

sub fetch_hosts {
    return qw{static.rust-lang.org};
}

1;
