package Provisioner::Recipe::Ubuntu::mailrelay;

#ABSTRACT: What the mail relay needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::mailrelay};

=head1 NAME

Provisioner::Recipe::Ubuntu::mailrelay - Ubuntu's C<deps> and C<dep_conflicts> for L<Provisioner::Recipe::mailrelay>.

=cut

=head2 @pkgs = $recipe->deps()

postfix, dovecot, the SPF policy of postfix, opendkim and opendmarc, the
stream module of nginx, which passes the mail clients, C<ipset>, which holds
the bans, C<libcryptx-perl> for the passwords that C<relay_client mail
register> makes, C<libcpanel-json-xs-perl> for milterprobe, with which the
guest test gives a milter a message, and C<libdata-validate-domain-perl>.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->deps();

=cut

# libcryptx-perl is for the passwords that relay_client mail register makes, and
# libcpanel-json-xs-perl for milterprobe, with which the guest test gives a
# milter a message.  templates/files/milter_client.tt installs milterprobe.
# The stream module of nginx passes the mail clients, and ipset holds the bans.
sub deps {
    return qw{postfix dovecot-core libcryptx-perl postfix-policyd-spf-python opendkim opendmarc libcpanel-json-xs-perl libnginx-mod-stream ipset libdata-validate-domain-perl};
}

=head2 @pkgs = $recipe->dep_conflicts()

C<sendmail>, because the relay is postfix.

Returns a list of Str, the names of the packages.

    my @pkgs = $recipe->dep_conflicts();

=cut

sub dep_conflicts {
    return qw{sendmail};
}

1;
