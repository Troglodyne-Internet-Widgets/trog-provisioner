package Provisioner::Recipe::mail;

#ABSTRACT: Set up and configure a full mailserver stack.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 Provisioner::Recipe::mail

=head2 SYNOPSIS

    somedomain:
        mail:
            relay:
                host: "mail.somerelay.net"
                port: 25025
                to:
                    - "somesite.net"
            names:
                me:
                    gecos: "Me"
                    password: "@Test_123!"
                you:
                    gecos: "You"
                    password: "@Test_123!"
                    mailboxes:
                        - "INBOX.foo"
                        - "INBOX.bar"
            mail_aliases:
                - from: "Me"
                  to: "you"
                - from: "You"
                  to: "me"

=head2 DESCRIPTION

Set up and configure a mail server.  postfix sends and receives mail.  dovecot
serves IMAP and POP3, and puts the mail that postfix gives it into the
mailboxes.  amavis, opendmarc and opendkim filter and sign the mail.

The recipe can relay SMTP through another host.  C<relay.to> limits the relay
to mail for the destinations it names.  The other defaults are sane.

The recipe makes the virtual users you specify, with their passwords and
mailboxes.

Put existing mailboxes in C<$install_dir/$domain/mailnames/>.  If
C<mailnames/$USER/$USER.sieve> exists, the recipe links it as
C<.dovecot.sieve> and compiles it with sievec.

Give each password as a C<secret:> reference, not in the clear.  See
L<Trog::Secrets>.

=head3 Two domains on one guest

postfix, opendkim and opendmarc each keep their configuration in a single file
with no C<conf.d>.  Also, C<postconf -e> B<sets> a parameter and cannot add to
one.  If the recipe writes those files, a second domain on the guest replaces
the configuration of the first.

So this recipe writes fragments, not files.  It pulls in the C<configd> recipe
to adopt those three files.  These things go into the fragment directories:

=over 4

=item * C</etc/postfix/main.cf.d/40-mail> and C</etc/postfix/master.cf.d/40-mail>,
from the global half.  They hold the mail stack of the guest, said once.  The
milters are here because configd joins C<smtpd_milters> across fragments.  If
two domains each name opendkim, postfix signs every message two times.

=item * C</etc/postfix/main.cf.d/50-E<lt>domainE<gt>> and
C</etc/opendmarc.conf.d/50-E<lt>domainE<gt>>, one for each domain.  These are
the parts that name the domain.  configd joins C<masquerade_domains>,
C<virtual_mailbox_domains> and every parameter that names a lookup table
across domains.  So each domain gets what it asked for.

=item * C</etc/opendkim.conf.d/40-mail>, from the global half, because nothing
in it is specific to a domain.

=item * C</etc/postfix/domains/E<lt>domainE<gt>/>.  This is not a configd
fragment directory.  It holds the lookup tables of the domain: the virtual
maps, the transport and relay maps, the header checks and the sender-login
map.  The main.cf fragment of the domain names each table, and postfix
searches the list.  So a second domain adds its own tables.

=back

=head3 Address classes

C<virtual_mailbox_domains> is the domain itself.  C<mydestination> is
C<$myhostname> and C<localhost>.  No domain is in both.  The
C<VIRTUAL_README> of postfix says: "NEVER list a virtual MAILBOX domain name
as a mydestination domain!"  A domain in two address classes has no defined
set of valid recipients.

postfix checks recipients by itself.  It rejects a recipient that is not in
C<virtual_mailbox_maps> with "User unknown in virtual mailbox table".

=head3 Who can send as whom

C<smtpd_sender_login_maps> names the C<sender_login> table of this domain, and
C<reject_authenticated_sender_login_mismatch> enforces it.  The check comes
before C<permit_sasl_authenticated>, because a restriction list stops at the
first permit.  So one authenticated user cannot send as another.

Know this consequence.  postfix also refuses an authenticated client whose
C<MAIL FROM> is B<absent> from that table, because nobody owns that address.
So the recipe makes the table from the accounts and the mail aliases together.
If a user sends from an address that neither of them names, that mail does not
go out.  The table does not apply to unauthenticated senders.  DMARC decides
what to do about those.

=head3 What a rebuild keeps, and what that costs

C<remote_files> names two things: the mail store of this domain, and
C</mail/keys>.

C</mail/keys> is not where opendkim keeps its keys.  opendkim owns
C</etc/opendkim/keys>, and C</mail/keys> is a copy for the fetch to read.
C<bin/new_config> reads the guest as root, so it can read
C</etc/opendkim/keys> directly.  A possible follow-up is to point
C<remote_files> at that directory and drop the copy.  The copy is
C<root:root>, 0600 in a 0700 directory.  That is as tight as it can be for a
file outside the daemon that owns the original.

The recipe salvages the mail store where it is.  Its mode is C<2750>, owned by
C<dovecot:dovecot>.  This is necessary.  dovecot copies the mode and the group
of the nearest parent onto every maildir and message file that it makes.  So
the group and the setgid bit on C</mail/E<lt>domainE<gt>> decide the group and
the mode of the whole store.

On the guest, only C<dovecot>, C<opendkim> and root can read these files.  But
the fetched copy goes into the data directory of the provisioner and into its
backups.  That copy holds all the mail of this domain and the key that signs
its outbound mail.

=head3 What cannot come apart

postfix has one C<myhostname> and one TLS certificate, and C</etc/aliases> is
one file.  So the last domain provisioned sets all three.  C<configd status
postfix> shows these disagreements, because it lists the fragments and what
wrote them.

=cut

use UUID                  qw{uuid};
use MIME::Base64          qw{encode_base64};
use Crypt::Digest::SHA512 qw{sha512};

sub required_recipes {
    my ( $self, %opts ) = @_;

    # configd gives main.cf, master.cf, opendkim.conf and opendmarc.conf the
    # fragment directories that the templates here write into.
    return (
        configd => sub { return ( languages => [qw{opendkim opendmarc postfix}] ) },
        $self->SUPER::required_recipes(%opts),
    );
}

sub args {
    return (
        type       => 'object',
        properties => {
            names => {
                type                 => 'object',
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{password gecos}],
                    properties => {
                        password => {
                            type => 'string',

                            # The template renders a salted_sha_512 hash, so
                            # the payload never holds the plaintext.  A literal
                            # password stays in the configuration file, and
                            # bin/preflight says so.
                            description => 'The mailbox password.  Write it as a secret: reference; the value belongs in the store rather than in recipes.d.',
                        },
                        gecos => { type => 'string' },

                        # The mailboxes that doveadm makes for this account,
                        # in addition to INBOX.
                        mailboxes => { type => 'array', items => { type => 'string' }, default => [] },
                    },
                },
            },
            mail_aliases => {
                type    => 'array',
                default => [],
                items   => {
                    type       => 'object',
                    required   => [qw{from to}],
                    properties => {
                        from => { type => 'string' },
                        to   => { type => 'string' },
                    },
                },
            },
            relay => {
                type       => "object",
                default    => {},
                properties => {
                    host => { type => "string" },
                    port => { type => "integer", minimum => 0 },
                    to   => { type => "array",   items   => { type => "string" }, default => [] },
                },
            },

            # bin/new_config fills this from the aliases block of the
            # configuration.
            full_aliases => {
                type    => 'array',
                default => [],
                items   => { type => 'string' },
            },
            ipv6 => { type => 'boolean', default => 1 },
        },
    );
}

=head2 @claims = $recipe->listens()

The ports of postfix: SMTP on 25, SMTP over TLS on 465 and submission on 587,
on every address, and the return from amavis on 10025, on 127.0.0.1.  The
ports of dovecot, on every address: POP3 on 110 and 995, IMAP on 143 and 993.
C<postgrey> on 10023, on 127.0.0.1.  amavis on 10024 and C<spamd> on 783, both
on 127.0.0.1 and on ::1.

=cut

sub listens {
    return (
        qw{25 465 587 110 995 143 993 127.0.0.1:10025 127.0.0.1:10023},
        map { ( "127.0.0.1:$_", "[::1]:$_" ) } 10024, 783
    );
}

=head2 %jails = $recipe->jails()

The jails that fail2ban ships for postfix and dovecot.  They ban a host whose
logins to SMTP, IMAP or POP fail too often, and read both from the journal.

=cut

sub jails {
    return (
        postfix => {},
        dovecot => {},
    );
}

=head2 @names = $recipe->subdomains()

C<mail>, which the MX names and the SRV records point at, and C<autodiscover>
and C<autoconfig>, which F<mail.autodiscover_vhost.tt> answers for so a client
can find its own settings.

=cut

sub subdomains {
    return qw{mail autodiscover autoconfig};
}

sub template_files {
    my ( $self, @recipes ) = @_;

    return (
        'mail.aliases.tt'                => 'aliases',
        'mail.header_checks.tt'          => 'header_checks',
        'mail.virtual_maps.tt'           => 'virtual_maps',
        'mail.virtual_aliases.tt'        => 'virtual_aliases',
        'mail.transport_maps.tt'         => 'transport_maps',
        'mail.sdd_relay_maps.tt'         => 'sdd_relay_maps',
        'mail.sender_login.tt'           => 'sender_login',
        'mail.dovecot.tt'                => 'dovecot.conf',
        'mail.dovecot.domain.tt'         => 'dovecot.domain.conf',
        'mail.passwd.tt'                 => 'mailpasswd',
        'mail.opendkim.tt'               => 'opendkim.conf',
        'mail.opendkim-trustedhosts.tt'  => 'TrustedHosts',
        'mail.opendkim-signingtable.tt'  => 'SigningTable',
        'mail.opendkim-keytable.tt'      => 'KeyTable',
        'mail.opendkim-internalhosts.tt' => 'InternalHosts',
        'mail.opendmarc.tt'              => 'opendmarc.conf',
        'mail.opendmarc-ignorehosts.tt'  => 'ignore.hosts',
        'mail.postfix.master.tt'         => 'master.cf',
        'mail.postfix.main.global.tt'    => 'main.cf.global',
        'mail.postfix.main.tt'           => 'main.cf.domain',
        'mail.amavis.tt'                 => '50-user',
        'mail.autodiscover.tt'           => 'autodiscover.xml',
        'mail.autodiscover_vhost.tt'     => 'autodiscover_vhost',
        'mail.cron.tt'                   => 'mailcron',
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Every address that an authenticated user of this domain can put in MAIL
    # FROM, and the login that owns it.  See "Who can send as whom" in the POD.
    #
    # The SASL login name is the full address, because the dovecot passwd file
    # uses the full address as its key.
    my @logins = map { { address => "$_\@$opts{domain}", owner => "$_\@$opts{domain}" } }
      sort keys %{ $opts{names} // {} };

    # The owner of an alias is the address it delivers to.  `to` is a local
    # part or a full address, so only a local part gets the domain appended.
    push @logins, map {
        {
            address => "$_->{from}\@$opts{domain}",
            owner   => Provisioner::Utils::qualify_address( $_->{to}, $opts{domain} ),
        }
    } @{ $opts{mail_aliases} // [] };

    $opts{sender_logins} = \@logins;

    return %opts;
}

sub formatters {
    my ($class) = shift;
    return (
        salted_sha_512 => Text::Xslate::html_builder(
            sub {
                my $pw   = shift;
                my $salt = uuid();

                # https://doc.dovecot.org/2.3/configuration_manual/authentication/password_schemes/#salting
                my $raw = encode_base64( sha512("$pw$salt") . $salt );
                $raw =~ s/\n//g;
                return "{SSHA512}$raw";
            }
        ),
    );
}

sub datadirs {
    return ('.mail');
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # Not the inverse of remote_files, so it is not derived from it.  The
    # fetch takes all of /mail/keys, and one directory of it goes back to
    # /etc/opendkim/keys.
    return (
        "/etc/opendkim/keys/$domain" => { from => "$install_dir/$domain/.mail/keys/$domain", owner => 'opendkim:opendkim' },
        "/mail/$domain"              => { from => "$install_dir/$domain/mailnames",          owner => 'dovecot:dovecot' },
    );
}

sub remote_files {
    my ( $class, $install_dir, $domain ) = @_;
    return (
        '/mail/keys'    => '.mail/keys',
        "/mail/$domain" => 'mailnames',
    );
}

sub tests {
    return qw{mail.tt};
}

1;
