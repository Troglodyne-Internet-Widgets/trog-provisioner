package Provisioner::Recipe::go;

#ABSTRACT: Install a Go toolchain from the release archive of go.dev.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::go

=head2 SYNOPSIS

    somedomain:
        go:

    # Or naming the release, with the SHA-256 of its archive:
    somedomain:
        go:
            version: "1.27.4"
            sha256: "7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"

=head2 DESCRIPTION

The Go toolchain of a release of go.dev, in F</usr/local/go>, with C<go>
and C<gofmt> linked into F</usr/local/bin>.  The distribution packages a Go
that is older than what some programs ask for in their F<go.mod>, so this
takes the release archive that go.dev publishes, as go.dev says to install
it.

That is the global half, because a toolchain is a fact about the machine
rather than about a domain.  The fragment downloads the archive only when
F</usr/local/go> holds another release, and refuses an archive whose SHA-256
is not C<sha256>.  So a new C<version> needs its C<sha256> too, which
L<https://go.dev/dl/?mode=json> lists for each archive.

C<go> fetches the toolchain that a F<go.mod> names when it is newer than this
one, unless C<GOTOOLCHAIN=local> is set, and nobody checked that toolchain.
So a build on the guest sets it, as F<scripts/build_loccount.sh> does.

=head2 WHO GETS IT

Every account.  F</usr/local/bin> is on the C<PATH> of each, and the
toolchain under F</usr/local/go> is readable by each.  A build still needs a
C<GOCACHE> and a C<GOPATH> that it can write, which C<go> takes from
C<$HOME> when they are not set.

=head3 deps

None.  The fragment needs C<curl>, C<sha256sum> and C<tar>, which every
image has.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            version => {
                type        => 'string',
                pattern     => '^\d+[.]\d+(?:[.]\d+)?$',
                default     => '1.27.4',
                description => 'The release of Go, as go.dev names it without the go in front, such as 1.27.4.',
            },
            sha256 => {
                type        => 'string',
                pattern     => '^[0-9a-f]{64}$',
                default     => '7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840',
                description => 'The SHA-256 of go<version>.linux-amd64.tar.gz, as https://go.dev/dl/?mode=json lists it.  The default is that of the default version, so a configuration that names a version names this too.',
            },
        },
    );
}

sub tests {
    return qw{go.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

C<go.dev>, which the URL of the archive names, and C<dl.google.com>, where
go.dev redirects the download.

=cut

sub fetch_hosts {
    return qw{go.dev dl.google.com};
}

1;
