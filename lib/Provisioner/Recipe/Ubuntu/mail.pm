package Provisioner::Recipe::Ubuntu::mail;

#ABSTRACT: What mail needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::mail};

=head1 NAME

Provisioner::Recipe::Ubuntu::mail - Ubuntu's C<deps> and C<dep_conflicts> for L<Provisioner::Recipe::mail>.

=cut

=head2 $recipe->deps()

postfix with its PCRE maps and SASL modules, dovecot with its protocols and
plugins, postgrey, opendmarc, opendkim, spamassassin, unbound, clamav,
amavisd-new with the unpackers that it scans archives with, and
C<libcpanel-json-xs-perl> for milterprobe, with which the guest test gives a
milter a message.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

# libcpanel-json-xs-perl is for milterprobe, with which the guest test gives a
# milter a message.  templates/files/milter_client.tt installs milterprobe.
sub deps {
    return qw{postfix postfix-pcre libsasl2-modules dovecot-imapd dovecot-pop3d dovecot-antispam dovecot-sieve dovecot-managesieved dovecot-lmtpd postgrey opendmarc opendkim spamassassin unbound clamav amavisd-new rpm2cpio 7zip bzip2 lrzip lzop unrar-free libcpanel-json-xs-perl};
}

=head2 $recipe->dep_conflicts()

C<sendmail>, because the mail server is postfix.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->dep_conflicts();

=cut

sub dep_conflicts {
    return qw{sendmail};
}

1;
