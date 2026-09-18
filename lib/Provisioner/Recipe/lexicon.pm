package Provisioner::Recipe::lexicon;

#ABSTRACT: dns-lexicon itself: the client, its patches, and the per-domain shortcut.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::DNSRecipe();

=head1 Provisioner::Recipe::lexicon

=head2 SYNOPSIS

    somedomain:
        lexicon:

=head2 DESCRIPTION

The client anything here writes a DNS record with.  Required by each recipe that
runs it rather than configured by hand: L<Provisioner::Recipe::pdns> and
L<Provisioner::Recipe::registrar> hold zones, and
L<Provisioner::Recipe::letsencrypt>'s dehydrated hook answers a dns-01 challenge
through it.

Three recipes owned a piece of it before.  letsencrypt installed the package,
pdns applied the patches, and each DNS recipe installed a shortcut of its own --
so a guest with pdns and no letsencrypt patched and invoked a client nothing had
installed.

=head2 What it takes to reach a zone is not its business

Which provider holds a domain's zone, and what lexicon authenticates to it with,
is L<Provisioner::DNSRecipe/credentials_for>.  This renders what that answers.

=head2 The shortcut

F</opt/lexicon/E<lt>domainE<gt>>, with the credentials already in it:

    /opt/lexicon/my.domain.name list TXT

A file rather than a directory holding one file per provider.  A domain has one
zone and one provider holding it, so the provider in the path distinguished
nothing -- and F<scripts/install_dkim_records> and letsencrypt's own SYNOPSIS
had both always spelled it flat.

=cut

=head2 %schema = $recipe->args()

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            dns_preference => {
                type        => 'string',
                enum        => [qw{pdns registrar}],
                description =>
                  'Which recipe holds this zone, where the guest has more than one that could.  The same tiebreaker Provisioner::Recipe::letsencrypt takes, and a guest running that needs nothing here: it resolves the provider and hands the answer down.  Set it here for a guest that has both a server of its own and registrar credentials and does not run letsencrypt -- pdns and registrar each require this recipe without saying which of them holds the zone, so there is nothing else to settle the tie and the build stops until somebody does.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{lexicon} = { Provisioner::DNSRecipe->credentials_for(%opts) };

    return %opts;
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'lexicon.shortcut.sh.tt'                       => 'lexicon.sh',
        'patches/lexicon-pdns-af-unix.patch'           => 'lexicon-pdns-af-unix.patch',
        'patches/lexicon-arbitrary-record-types.patch' => 'lexicon-arbitrary-record-types.patch',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests {
    return qw{lexicon.tt};
}

1;
