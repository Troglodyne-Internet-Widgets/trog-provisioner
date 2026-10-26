package Provisioner::Recipe::mailrelay;

#ABSTRACT: Relay the mail of other guests, out to the internet and in from it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Provisioner::Cookbook();
use Provisioner::IPPool();
use Provisioner::Vars();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::mailrelay

=head2 SYNOPSIS

    relay.somedomain:
        mailrelay:

    internal.somedomain:
        mail:
            relay:
                host: relay.somedomain

=head2 DESCRIPTION

Makes this guest the mail server, for the internet, of the guests whose
C<mail.relay.host> names it.  This is for a guest that cannot send
or take mail on port 25 itself, such as one behind an ISP that blocks it.  The
reverse DNS and the SPF of the domain can then name this guest.  See
L<Provisioner::Recipe::mail/Sending through a mail relay>.

It runs a postfix, so it cannot be on one machine with
L<Provisioner::Recipe::mail>.  It does not need
L<Provisioner::Recipe::nginxrelay>, but a guest that fronts the web and the
mail of the guests behind it runs both.

=head2 Mail out

When the guest is built, C<mailrelay_client register> makes a login for its
domain, with a new password that it prints and does not keep.  The guest
places the password as a grant.  F</etc/postfix/mailrelay.d> keeps the hash,
for dovecot, which checks the logins for postfix and does nothing else.  It
also keeps the senders that each login owns, which is every address in its
domain.  So a guest cannot send as another domain through this relay.

The relay is postfix on C<relay_port>, bound to the address where the guests
reach this guest, and not to the public address.  It takes mail only over TLS,
only from a login, and only with a sender that the login owns.  It then
delivers the mail itself, on port 25.  C<bin/destroy> runs
C<mailrelay_client release>, which removes the login.

=head2 Mail in

The registration of L</Mail out> also makes this guest take the mail of the
domain from the internet, on 25, and relay it to the guest of the domain over
the tunnel.  C<mailrelay_client register> gets the address of that guest from
the grant, and writes the domain into C<relay_domains>, its route into
C<transport_maps>, and C<@domain> into C<relay_recipient_maps>.  The guest
delivers any address of its domain to its catchall, so the relay takes every
recipient there.  Mail for any other domain is refused.

The relay makes the checks that a mail guest makes of a client: reverse DNS,
RBLs and C<HELO>, from F<templates/files/postfix.smtpd_restrictions.tt>, which
both include.  The guest then trusts the address of the relay, because only the
relay knows who the client was.  fail2ban bans here an address that fails too
often.  The reverse DNS of the public address of this guest must name it, or
the receivers of what it sends will refuse it.

=head2 SPF

The guest behind the relay sees the relay as the client of every message that
comes in, so only the relay can check the SPF of the sender.  On 25, before the
message:

=over 4

=item * The SPF policy service, C<policyd-spf>, refuses a sender that fails
SPF.  It adds nothing to the message.

=item * opendkim verifies the signatures, and signs nothing.  It removes every
C<Authentication-Results> under the name of this guest that the message
brought in, because the guests behind the relay trust that name.  Without it, a
client could write a pass of its own under that name.

=item * opendmarc then checks SPF against the client, and writes its verdicts
under the name of this guest.

=back

The opendmarc of the guest trusts that name, and takes the SPF verdict of the
relay for DMARC.  It checks DKIM itself, which does not depend on the client.
See L<Provisioner::Recipe::mail/Sending through a mail relay>.  The relay for
the mail of the guests runs neither, because that mail is theirs.

=cut

sub args {
    return (
        properties => {
            relay_port => {
                type        => 'integer',
                minimum     => 1024,
                maximum     => 65535,
                default     => 2587,
                description => 'The port of the relay that the guests behind this one send their mail through.  See "Mail out".',
            },
        },
    );
}

# Defaulted here as well as in args, because rate_limits and relay_port_of run
# before validation, or without it.
my sub relay_port (%opts) {
    return $opts{relay_port} // 2587;
}

sub required_recipes {
    return (
        configd     => sub { return ( languages           => [qw{postfix opendkim opendmarc}] ) },
        letsencrypt => sub { return ( certificate_readers => ['postfix'] ) },
    );
}

=head2 %limits = $recipe->rate_limits(%opts)

The limit of a port of mail for C<relay_port>, and for 25, where the mail of
the internet comes in.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;
    return ( relay_port(%opts) => 64, 25 => 64 );
}

=head2 %jails = $recipe->jails()

The jail that fail2ban ships for postfix, because the relay takes mail from the
internet on 25.  It bans here, where the client connects.

=cut

sub jails {
    return ( postfix => {} );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<relay_address>, where the guests reach this guest, as C<reachable_address>
in L<Provisioner::IPPool> gives it, and where the relay listens.  Adds
C<helo_name>, which is C<helo_name_of> in L<Provisioner::Cookbook>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{relay_address} = Provisioner::IPPool::reachable_address( $opts{domain} );
    $opts{helo_name}     = Provisioner::Cookbook->helo_name_of( $opts{domain} );
    return %opts;
}

=head2 $bool = $recipe->sends_mail

True, because the relay delivers the mail of the guests to the internet.  See
L<Provisioner::Recipe>.

=cut

sub sends_mail {
    return 1;
}

=head2 @names = $recipe->exclusive_on_machine_with

C<mail>, because the postfix of each answers port 25 of the machine, and a
machine has one postfix.  See L<Provisioner::Recipe>.

=cut

sub exclusive_on_machine_with {
    return qw{mail};
}

=head2 $port = $recipe->relay_port_of($relay)

The C<relay_port> of the guest C<$relay>, from its configuration, or the
default when it sets none.

=cut

sub relay_port_of {
    my ( $self, $relay ) = @_;
    return relay_port( %{ Provisioner::Cookbook->domain_config($relay)->{mailrelay} // {} } );
}

=head2 $path = $recipe->password_path($domain)

Where the password of the login that this guest issues for C<$domain> is, on
the guest of C<$domain>.

=cut

sub password_path {
    my ( $self, $domain ) = @_;
    return "/etc/postfix/mailrelay/$domain.password";
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

F</etc/postfix/mailrelay.d>, which holds the registrations.  Without it, a
rebuilt relay takes no mail from a guest, and for none, until each guest behind
it is built again.

=cut

sub remote_files {
    return ( '/etc/postfix/mailrelay.d/' => 'mailrelay.d/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvage of F</etc/postfix/mailrelay.d> goes back there.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return ( '/etc/postfix/mailrelay.d' => { from => "$install_dir/$domain/mailrelay.d", owner => 'root:root' } );
}

=head2 %files = $recipe->issue_grant($grant, %terms)

The password of the login that this guest issues for the client of C<$grant>,
at C<password_path> of the client, as C<issue_grant> in L<Provisioner::Recipe>
says.  C<%terms> has C<< address => $address >>, where the relay sends the mail
of the client that comes in.  The command is F<scripts/mailrelay_client>
C<register>, which root runs on this guest.  See L</Mail out> and L</Mail in>.

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};

    return (
        $self->password_path($client) => {
            issue => { guest => $grant->{guest}, command => "$Provisioner::Vars::SCRIPT_DIR/mailrelay_client register $client $terms{address}" },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 %revocation = $recipe->revoke_grant($grant)

The removal of the login and the route in of the client of C<$grant>, by
F<scripts/mailrelay_client> C<release>, as C<revoke_grant> in
L<Provisioner::Recipe> says.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client  = $grant->{client};
    my $command = "$Provisioner::Vars::SCRIPT_DIR/mailrelay_client release $client";
    return (
        command => $command,
        doing   => "remove the relay login of $client",
        done    => "Removed the relay login of $client",
        stays   => "its relay still takes mail from the login of $client, and relays the mail of $client to its old address.  Run $command there",
    );
}

sub template_files {
    return (
        'mailrelay.postfix.main.tt'   => 'mailrelay.postfix.main',
        'mailrelay.postfix.master.tt' => 'mailrelay.postfix.master',
        'mailrelay.dovecot.tt'        => 'mailrelay.dovecot.conf',
        'mailrelay.policyd_spf.tt'    => 'mailrelay.policyd_spf',
        'mailrelay.opendkim.tt'       => 'mailrelay.opendkim.conf',
        'mailrelay.opendmarc.tt'      => 'mailrelay.opendmarc.conf',
        'mailrelay.ufw.conf.tt'       => 'mailrelay_ufw.conf',
    );
}

sub tests {
    return qw{mailrelay.tt};
}

1;
