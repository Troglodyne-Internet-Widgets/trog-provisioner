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

This recipe installs lexicon, the client that every recipe here uses to write a
DNS record.  It also applies two patches to lexicon and installs a shortcut for
the domain.

You do not usually configure it yourself.  Each recipe that runs lexicon requires
it.  L<Provisioner::Recipe::pdns> and L<Provisioner::Recipe::registrar> hold
zones.  The dehydrated hook of L<Provisioner::Recipe::letsencrypt> answers a
dns-01 challenge through lexicon.

=head2 What it takes to reach a zone is not its business

L<Provisioner::DNSRecipe/credentials_for> says which provider holds the zone of a
domain, and which credentials lexicon uses for it.  This recipe renders that
answer.

=head2 The shortcut

The shortcut is F</opt/lexicon/E<lt>domainE<gt>>, and it contains the
credentials:

    /opt/lexicon/my.domain.name list TXT

It is a file, not a directory with one file for each provider.  A domain has one
zone and one provider, so the path does not name the provider.

=cut

=head2 %schema = $recipe->args()

Returns the schema.  C<bin/recipes> shows each field and its description.

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

Returns C<%opts> with C<lexicon> added: the credentials that
L<Provisioner::DNSRecipe/credentials_for> returns for the domain.  It dies when
C<credentials_for> dies, for example when no provider or two providers can
answer for the zone.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{lexicon} = { Provisioner::DNSRecipe->credentials_for(%opts) };

    return %opts;
}

=head2 %files = $recipe->template_files()

Returns the shortcut template and the two patches, each mapped to the name of
the file that it becomes.

=cut

sub template_files {
    return (
        'lexicon.shortcut.sh.tt'                       => 'lexicon.sh',
        'patches/lexicon-pdns-af-unix.patch'           => 'lexicon-pdns-af-unix.patch',
        'patches/lexicon-arbitrary-record-types.patch' => 'lexicon-arbitrary-record-types.patch',
    );
}

=head2 @tests = $recipe->tests()

Returns the guest test F<lexicon.tt>.

=cut

sub tests {
    return qw{lexicon.tt};
}

1;
