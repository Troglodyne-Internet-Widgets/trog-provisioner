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

# libcryptx-perl is for the passwords that mailrelay_client makes, and
# libcpanel-json-xs-perl for milterprobe, with which the guest test gives a
# milter a message.  templates/files/milter_client.tt installs milterprobe.
# The stream module of nginx passes the mail clients, and ipset holds the bans.
sub deps {
    return qw{postfix dovecot-core libcryptx-perl postfix-policyd-spf-python opendkim opendmarc libcpanel-json-xs-perl libnginx-mod-stream ipset};
}

# The relay is postfix, which conflicts with the sendmail of every other guest.
sub dep_conflicts {
    return qw{sendmail};
}

1;
