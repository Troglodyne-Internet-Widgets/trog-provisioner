package Provisioner::Recipe::lexicon;

#ABSTRACT: dns-lexicon itself: the client, its patches, and the per-domain shortcut.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Cookbook();

=head1 Provisioner::Recipe::lexicon

=head2 SYNOPSIS

    somedomain:
        lexicon:

=head2 DESCRIPTION

This recipe installs lexicon, the client that every recipe here uses to write a
DNS record.  It also applies four patches to lexicon and installs a shortcut
for the domain.  One of the patches lets a C<CNAME> in a pdns zone name a
target outside that zone, as the names in a zone of a registrar account need.
Another lets the easydns provider take an C<MX> or C<SRV> record as the
powerdns provider does, with its whole RDATA in the content, such as
C<10 mail.example.com.>.  The provider sends the priority to easyDNS in a
field of its own.

You do not usually configure it yourself.  Each recipe that runs lexicon requires
it.  L<Provisioner::Recipe::pdns> and L<Provisioner::Recipe::registrar> hold
zones.  The dehydrated hook of L<Provisioner::Recipe::letsencrypt> answers a
dns-01 challenge through lexicon.

=head2 What it takes to reach a zone is not its business

L<Provisioner::Recipe::registrar/credentials_for> says which server holds the
zone of a domain, and which credentials lexicon uses for it.  This recipe
renders that answer.

=head2 The shortcut

The shortcut is F</opt/lexicon/E<lt>domainE<gt>>, and it contains the
credentials:

    /opt/lexicon/my.domain.name list TXT

It is a file, not a directory with one file for each provider.  A domain has one
zone and one provider, so the path does not name the provider.

=cut

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with C<lexicon> added: the credentials that
L<Provisioner::Recipe::registrar/credentials_for> returns for the domain.  It
dies when C<credentials_for> dies, for example when no server of this
installation holds the zone and the registrar names no provider.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{lexicon} = { Provisioner::Cookbook->load('registrar')->credentials_for(%opts) };

    return %opts;
}

=head2 %files = $recipe->template_files()

Returns the shortcut template and the four patches, each mapped to the name
of the file that it becomes.

=cut

sub template_files {
    return (
        'lexicon.shortcut.sh.tt'                       => 'lexicon.sh',
        'patches/lexicon-pdns-af-unix.patch'           => 'lexicon-pdns-af-unix.patch',
        'patches/lexicon-arbitrary-record-types.patch' => 'lexicon-arbitrary-record-types.patch',
        'patches/lexicon-pdns-absolute-cname.patch'    => 'lexicon-pdns-absolute-cname.patch',
        'patches/lexicon-easydns-priority.patch'       => 'lexicon-easydns-priority.patch',
    );
}

=head2 @tests = $recipe->tests()

Returns the guest test F<lexicon.tt>.

=cut

sub tests {
    return qw{lexicon.tt};
}

1;
