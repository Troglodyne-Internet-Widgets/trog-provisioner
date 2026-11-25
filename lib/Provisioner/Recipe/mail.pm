package Provisioner::Recipe::mail;

#ABSTRACT: Set up and configure a full mailserver stack.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

use parent qw{Provisioner::Recipe};

use Provisioner::Cookbook();
use Provisioner::IPPool();
use Provisioner::MailAccount();
use Provisioner::Utils();
use Trog::Secrets();

use Crypt::PK::RSA();
use Data::Validate::IP();
use MIME::Base64();

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

=head3 Spam

amavis scores each message with SpamAssassin, and marks spam with
C<X-Spam-Flag: YES>.  The package turns that check off, and the recipe turns it
back on.  A global sieve, which runs before the sieve of each user, files marked
mail into C<Junk Email>.  Every account has that folder, with the C<\Junk>
special use that mail clients look for.

=head3 The special-use folders, and their aliases

dovecot declares four folders in the inbox namespace of every account, each
subscribed and each with its special use (RFC 6154): C<Sent Items> (C<\Sent>),
C<Deleted Items> (C<\Trash>), C<Junk Email> (C<\Junk>) and C<Drafts>
(C<\Drafts>).  Most clients use the folder that has the special use, whatever
its name.  Classic Outlook ignores the use and uses these names, which is why
they are the names.  Roundcube gets the same four names in C<sent_mbox>,
C<trash_mbox>, C<junk_mbox> and C<drafts_mbox>.  A client in a language other
than English makes folders with translated names.  The recipe does not cover
them, but C<mailbox_aliases> can.

C<mailbox_aliases> maps the name of a folder that another client makes to the
folder that it must reach.  The default is C<Junk> to C<Junk Email>, C<Sent> and
C<Sent Messages> to C<Sent Items>, and C<Trash> and C<Deleted Messages> to
C<Deleted Items>.  Thunderbird and Roundcube make C<Junk>, C<Sent> and
C<Trash>.  Apple Mail makes C<Sent Messages> and C<Deleted Messages>.  An entry that you write adds to the
default, and an entry with a default name changes its target:

    somedomain:
        mail:
            mailbox_aliases:
                Gesendet: Sent Items

A name and a target cannot hold a quote, a backtick, a percent sign, an
asterisk, a question mark, a dollar sign, a backslash, a slash, a dot, a hash
sign or a line break.  They cannot start with
a less-than sign, and they cannot start or end with white space.  The
configuration of dovecot has the names without quotes, and dovecot reads a hash
sign as the start of a comment, a leading less-than sign as the name of a file
to include, and white space at the ends as nothing.

The C<mailbox_alias> plugin of dovecot makes an alias a link to its target, and
creates, renames and deletes the alias without touching the target.  A link made
by hand is not safe, because dovecot keeps one index for each name, so the same
messages show under two sets of UIDs.  An alias that has no link is not safe
either: a client that deletes it deletes the messages of the target.  So the
build makes the link of each alias for each account in C<names>, and for the
catchall.  The plugin makes one for any other account when a client first
creates the alias.  The
plugin takes the target as its C<mailbox_alias_old> and the alias as its
C<mailbox_alias_new>.

The plugin can alias only a name that is not a real folder, and a restored store
can have a real folder under an alias name.  So for each account, the catchall
among them, and each alias, after the store is restored and before the training, the build does this
when the alias is a real folder.  It moves the messages into the target with
C<doveadm move>, then deletes the empty folder, and writes a line about it in
the setup log.  The move does not depend on whether the target exists, so
C<.Junk> of an old store merges into C<Junk Email>.

=head3 The Validity lists

F</etc/spamassassin/60-trog-mail.cf> belongs to this recipe.  It sets
C<RCVD_IN_VALIDITY_CERTIFIED>, C<RCVD_IN_VALIDITY_SAFE> and
C<RCVD_IN_VALIDITY_RPBL> to 0.  Validity answers "listed" to a resolver that
asks it too many questions, and the text of that answer says "Excessive Number
of Queries".  SpamAssassin counts any answer as a hit.  The first two rules
score -3.0 and -2.0, so a resolver over its quota gave nearly all mail from the
large senders a bonus, spam included.

=head3 The rules, every day

The package leaves C<spamassassin-maintenance.timer> off, so C<sa-update> never
ran and the guest scored with the rules of the package.  The build enables the
timer and runs C<sa-update> one time, so that a new guest does not wait a day.
amavis loads the rules when it starts.  So a drop-in of
C<spamassassin-maintenance.service> restarts amavis after a run that changed a
file of the rules.

C<sa-update> needs port 80 and 443 for the update hosts, and 53 for their
names.  The C<APT> profile of L<Provisioner::Recipe::ufw> opens all three for
every guest, so the recipe adds no hole.  It names no C<fetch_hosts>, because
the mirrors of the rules are many, and the list changes.

=head3 Bayes

Each night, C<sa_train_amavis> trains the Bayes database of amavis from the
folders of every account in C<names>.  Spam is the folder that dovecot gives the
C<\Junk> special use, which is C<Junk Email>, and each folder in C<names.$USER.spam_folders>, for
example C<INBOX.$spam>.  Ham is every other folder of the account, except the
folders with the C<\Trash>, C<\Drafts> and C<\Sent> special uses, which are
C<Deleted Items>, C<Drafts> and C<Sent Items>.  An alias, which is a link, is not
learned a second time.  INBOX is never learned, read
or not, because it holds mail that nobody has sorted.  The script reads the
special uses from the configuration of dovecot, which declares all four in
F<mail.dovecot.tt>.  A folder that is renamed there is found by its use.

A user who moves a message into a folder teaches the filter.  SpamAssassin uses
Bayes only after it has learned 200 messages of each kind.

The build does not salvage the Bayes database, so each build starts with an
empty one.  At the end of the target of each domain, after the mail store is
restored, the build runs the training one time.  An account that moved here
scores with Bayes from its first message.

=head3 Asking blocklists from this guest

SpamAssassin asks DNS blocklists about the address of the sender.  A large
shared resolver sends every question from an address that thousands of others
share, and a list answers such an address with "blocked".  URIBL answers
C<127.0.0.1> to C<2.0.0.127.multi.uribl.com> then, and SpamAssassin reports
C<URIBL_BLOCKED> and checks no URI.  A resolver of this guest sends the
questions from the address of this guest.

The recipe installs C<unbound>, which recurses from the root, and tells
SpamAssassin to ask it, with C<dns_server 127.0.0.2> in the file above.  It is
on by default where C<main_ip> is a public address: not in a private, loopback,
link-local or shared range.  A guest behind NAT keeps the resolvers of the
installation, because its questions leave from the address of the hypervisor
anyway.

To turn it on for a guest that is not public, or off for one that is, set it in
the configuration of the domain:

    somedomain:
        mail:
            local_resolver: false

Off, C<unbound> is stopped and SpamAssassin asks the first nameserver of
F</etc/resolv.conf>.

The recipe does not use L<Provisioner::Recipe::nostubresolver>, and does not
change the C<resolvers> of the installation.  Those name the servers that the
whole guest asks, and a guest with such a recipe still asks them for everything
else.  Port 53 does not clash, because the stub of systemd-resolved listens on
127.0.0.53 and 127.0.0.54, and C<unbound> listens on 127.0.0.2 alone.  A
C<pdns> on the same guest keeps 127.0.0.1.  C<unbound> recurses over port 53 to
the authoritative servers, which the C<APT> profile of the firewall opens.

=head3 Trusted clients

Port 25 refuses a client whose address has no reverse DNS, whose reverse DNS
does not resolve back to it, or that is on an RBL, and checks the sender.  A
server that you must hear from can fail those checks, for example a server
behind a home connection with no reverse DNS.  C<trusted_clients> names the
addresses of such servers:

    somedomain:
        mail:
            trusted_clients:
                - 192.0.2.7

A trusted client skips the checks of the client and of the sender.  It does
not skip the checks of the recipient, so it can deliver only to the domains of
this guest, as any other client can.  The list goes into the global half, so
every domain on a machine must name the same list.  L<Provisioner::Recipe::mailrelay>
takes the same setting.

=head3 Relay and accounts

The recipe can relay SMTP through another host.  C<relay.to> limits the relay
to mail for the destinations it names.  The other defaults are sane.

The recipe makes the virtual users you specify, with their passwords and
mailboxes.

Put existing mailboxes in C<$install_dir/$domain/mailnames/>, one directory
for each account, which becomes its home, C</mail/$domain/$USER>.  See
L</Sieve scripts, and ManageSieve> for the filters of each account.

Give each password as a C<secret:> reference, not in the clear.  See
L<Trog::Secrets>.

=head3 Sieve scripts, and ManageSieve

Each user edits the sieve scripts of the account in Roundcube, which talks to
the ManageSieve service of dovecot.  ManageSieve keeps the scripts of an
account in C<sieve/> in its home, and C<.dovecot.sieve> is a link to the
active one.  dovecot runs that script when it delivers, after the global sieve
of L</Spam>.

Bring the scripts of a mail store in one of two ways:

=over 4

=item * From a server that ran ManageSieve, copy the home as it is, with
C<sieve/> and the C<.dovecot.sieve> link.  The build leaves them alone.

=item * From a server that did not, put the one script of the account at
C<mailnames/$USER/$USER.sieve>.  When the home has no C<sieve/>, the build
moves the script to C<sieve/$USER.sieve>, makes it the active script, and
compiles it with sievec.  It then shows in Roundcube as C<$USER>.
F<scripts/import_sieve> does the move.

=back

A C<.dovecot.sieve> that is a plain file and not a link is left for dovecot.
The first time that the user activates a script, dovecot moves the file into
C<sieve/> as C<dovecot.orig>.

ManageSieve listens on 4190 on loopback only, because Roundcube is on this
guest.  See C<listens>.

=head3 Who may say that a message passed

opendmarc decides DMARC from the C<Authentication-Results> under the names it
trusts: C<mail.DOMAIN>, and the mail relay of the domain if it has one.  A
message can carry such a header from anywhere, and a client could write a pass
of its own.  So opendkim, which runs before opendmarc, removes every
C<Authentication-Results> under a name in F</etc/opendkim/RemoveARFrom>, which
lists the C<mail.DOMAIN> of each domain on the guest.  The mail relay removes
the ones under its own name.  See L<Provisioner::Recipe::mailrelay/SPF>.

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

=item * C</etc/amavis/conf.d/40-trog-mail>, from the global half, and
C</etc/amavis/conf.d/50-E<lt>domainE<gt>> for each domain, with each dot of the
domain written as an underscore.  amavis needs no configd: it reads every file
in that directory as Perl, in C<run-parts> order, and C<run-parts> skips a name
with a dot in it.  The file of the guest empties C<@local_domains_acl>, and the
file of each domain adds the domain to it.  amavis adds the spam headers only
for a recipient in that list.

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

C<remote_files> names the mail store of this domain.  The DKIM key is not
salvaged.  It is in the secret store, and C<bin/provision> puts it on the
guest.  See C<guest_secrets>.

The recipe salvages the mail store where it is.  Its mode is C<2750>, owned by
C<dovecot:dovecot>.  This is necessary.  dovecot copies the mode and the group
of the nearest parent onto every maildir and message file that it makes.  So
the group and the setgid bit on C</mail/E<lt>domainE<gt>> decide the group and
the mode of the whole store.

The store comes with the index files of the server that it was salvaged from,
such as F<dovecot-uidlist>.  dovecot trusts an index while the mtime of its
maildir is unchanged, and a copy keeps the mtime.  So a message that arrived
after the old server last indexed the maildir would stay out of every search
and every client.  The build runs C<doveadm force-resync> on every mailbox of
each account, which reads each maildir again, and changes no message.

On the guest, only C<dovecot>, C<opendkim> and root can read these files.  But
the fetched copy goes into the data directory of the provisioner and into its
backups.  That copy holds all the mail of this domain.

=head3 Accounts on a running guest

A rebuild is too much for a new address. Three tools change an account on the
running guest, and change the configuration with it, so that the next build
makes the same account:

    bin/add_mail_user DOMAIN NAME [--gecos TEXT] [--mailbox NAME ...]
    bin/reset_mail_password DOMAIN NAME [--kick]
    bin/remove_mail_user DOMAIN NAME [--kick]

C<add_mail_user> stores the password as C<secret:mail/DOMAIN-NAME/password>,
adds the account to C<mail.names> in F<recipes.d/DOMAIN.yaml>, and adds the line
to F</mail/DOMAIN/passwd> on the guest. The line is the one that the build
renders. Both call C<passwd_line> in L<Provisioner::MailAccount>. The tools
change that file through a temporary file and a rename, so dovecot never reads
half of it, and dovecot needs no restart. C<reset_mail_password> replaces the
value in the secret store and the hash in the one line. See the POD of each
tool.

Postfix has three tables of its own, F</etc/postfix/domains/DOMAIN/sender_login>,
F</etc/postfix/domains/DOMAIN/virtual_aliases> and
F</etc/postfix/domains/DOMAIN/virtual_maps>. Without a line in the first, the
account cannot send. Without one in the second or the third, its mail goes to
the catchall mailbox, because postfix reads the wildcard line at the end of
C<virtual_aliases> for every address that has no line of its own.
C<add_mail_user> adds a line to each, above the catchall line, and
C<remove_mail_user> takes the lines out. C<reset_mail_password> changes none,
because no table holds the password. The lines come from C<sender_login_line>,
C<virtual_aliases_line> and C<virtual_maps_line> in L<Provisioner::MailAccount>,
which the templates call too. Each table is written through a temporary file
and a rename, and then C<postmap> builds its database. Postfix rereads it, so
nothing reloads postfix. The tables are written before the passwd-file. If the
passwd-file cannot be written, the tables are put back.

An account that you add by hand on the guest, with none of these tools, is not
in C<mail.names>. The next build does not make it. See C<unlisted_accounts>.

=head3 An account that only the salvaged store knows

The build makes F</mail/DOMAIN/passwd> from C<mail.names> and moves the
salvaged file aside as F<passwd.old>. An address in the salvaged file that
C<mail.names> lacks has its mailbox, but it cannot log in. Before this check, the
build did not say so.

Now the build compares the two files, and C<unlisted_accounts> decides what it
does with each address that only the old one holds:

=over 4

=item * C<refuse>, which is the default. The build stops before it moves
anything, and the setup log names each address. The old file stays where it was.
Either add the account to C<mail.names> (C<bin/add_mail_user> does it), or
remove it (C<bin/remove_mail_user> does it), and build again. This is the
default because a build that restores a login that you removed from the
configuration is a security fault that nothing reports.

=item * C<keep>, which copies the line of each such address into the new file,
with its hash, and names the address in the setup log. Use it to move a store
whose accounts you cannot list yet.

=back

The guest test reads F<passwd.old> too. For each address in it, the test makes
sure that the address is in C<mail.names>, or in the new file under C<keep>. The
test also asks dovecot to look up each account in C<mail.names>. It then makes
sure that the number of messages that dovecot finds for the account is the number
of message files in its maildir. A store that was restored with the wrong owner
fails there. The test does not log in with the password, because the guest holds
only the hash, and the test would need the plain text.

=head3 Sending through a mail relay

    somedomain:
        mail:
            relay:
                host: relay.somedomain

When C<relay.host> is a guest of this installation, it must run
L<Provisioner::Recipe::mailrelay>, and the build stops when it does not.  Then
every message with a sender in this domain goes out through that guest, and not
straight to the internet.  This is for a guest that cannot send on port 25
itself, such as one behind an ISP that blocks it.  The relay sets its own
port, so C<relay.port> and C<relay.to> are refused there, because they are for
a host outside.  So the configuration of the relay guest decides how every
domain that names it sends its mail: a guest that gains or loses C<mailrelay>
changes them all.

When this domain is built, the mail relay issues it a password for a login of
its own, as a grant, and relays to this guest the mail of the domain that comes
in from the internet.  See L<Provisioner::Recipe::mailrelay/Mail out> and
L<Provisioner::Recipe::mailrelay/Mail in>.  This recipe puts the password in
the C<sasl_passwd> table of the domain, which postfix uses for a sender in this
domain.  It sends to the relay only over TLS, and the relay takes from this
login only a sender in this domain.  C<bin/destroy> removes the login on the
mail relay.

Every message from the internet comes to this guest from the address of the
relay, so the jails of this recipe never ban that address.  The relay bans the
real client itself, on its own port 25.

The mail clients of the domain reach this guest through the relay too, on 993,
465 and 995, which the relay passes by their SNI name with the PROXY protocol.
See L<Provisioner::Recipe::mailrelay/Mail clients>.  The relay registers the
domain and C<mail.DOMAIN>.  The guest takes them on C<proxied_ports>, where
dovecot and postfix read the PROXY header, so they see the real client.
postfix believes that header from any client, so the firewall drops those ports
from every address but a relay of a domain on this guest.
F</etc/mail-proxy-from.d> keeps one file of an address for each domain behind a
relay, and dovecot believes the header from those addresses only.  A failed
login of a client there comes from the relay, so the jails of this recipe also
ban through the relay, with the action C<mailrelay-DOMAIN>.  See
L<Provisioner::RelayRecipe/Bans>.

A message with an empty sender, such as a bounce that this guest makes, is not
in the domain, so it does not go through the mail relay.

The mail relay checks the SPF of the mail that it relays in, because this guest
sees only the relay as the client.  opendmarc here trusts the verdict that the
opendmarc of the relay writes under its name, in C<TrustedAuthservIDs>.  See
L<Provisioner::Recipe::mailrelay/SPF>.

=head3 What cannot come apart

postfix has one TLS certificate, C</etc/aliases> is one file, and opendmarc
has one C<AuthservID>.  So the last domain provisioned sets all three.  postfix
also has one C<myhostname>.  The global half sets it to C<helo_name_of> in
L<Provisioner::Cookbook>, which is one name for the machine, so every domain on
the guest gives the same one.  opendmarc still trusts the mail relay of every
domain, because configd joins the C<TrustedAuthservIDs> of every domain.
C<configd status postfix> shows these disagreements, because it lists the
fragments and what wrote them.

=head3 The settings of a mail client

A mail client can find its own settings, given only the address.
F<mail.autodiscover_vhost.tt> answers for C<autodiscover.DOMAIN> and
C<autoconfig.DOMAIN>, over HTTPS and over plain HTTP:

=over 4

=item * Outlook asks for C</autodiscover/autodiscover.xml>, with a POST, and
gets F<mail.autodiscover.tt>.  The SRV record C<_autodiscover._tcp> points it at
C<autodiscover.DOMAIN> on 443.

=item * Thunderbird asks C<autoconfig.DOMAIN> for C</mail/config-v1.1.xml>, and
gets F<mail.autoconfig.tt>.  The C<mailconf=> TXT record names the same file,
for the clients that read it.

=back

Both name C<mail.DOMAIN>, and the ports where TLS starts at once.  Behind a
relay of L<Provisioner::Recipe::nginx>, this recipe makes both names public
names, so that a client outside can fetch them.

Both also give the whole address as the user name, because dovecot and the
SASL of postfix know each account as C<$name@$domain>.  A client that is set up
by hand often gives the name alone, and then every login fails, with any
password.  So dovecot adds a domain to a name that has none, for IMAP, POP3 and
the SASL of postfix.  dovecot has one such default realm for the guest.  It is
the domain of the machine, C<machine_of> in L<Provisioner::Cookbook>, and never
a domain that C<_shared> builds onto it.  A user of a domain built onto another
gives the whole address.  When the machine itself has no mail, no domain of the
guest takes a bare name.

dovecot logs why each login fails (C<auth_verbose>), for example an unknown
user or a password mismatch.  The filter of the dovecot jail matches that line
as well as the line of the disconnect, so one failed login counts two times.
The jail allows ten matches, which is five failed logins.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    # configd gives main.cf, master.cf, opendkim.conf and opendmarc.conf the
    # fragment directories that the templates here write into.
    return (
        configd => sub { return ( languages => [qw{opendkim opendmarc postfix}] ) },
        cron    => sub { return ( files     => { "$opts{domain}-mailcron" => 'mailcron' } ) },
        nginx   => sub {
            my @sites = map { "$_.$opts{domain}" } qw{autodiscover autoconfig};
            return ( sites => \@sites ) unless defined( ( Provisioner::Cookbook->domain_config( $opts{domain} )->{nginx} // {} )->{relay} );
            return ( sites => \@sites, public_names => { map { $_ => { vhost => $_ } } @sites } );
        },
        letsencrypt => sub { return ( certificate_readers => [qw{postfix dovecot}] ) },
    );
}

# A value with no colon and no line break in it.
my $NO_COLON = qr/\A [^:\r\n]* \z/;

# A folder name for spam training, which only has to be free of a quote, a
# percent sign and a line break.
my $SPAM_FOLDER = qr/\A [^'%\r\n]+ \z/;

# A folder name with no quote, backtick, percent sign, asterisk, question mark,
# dollar sign, backslash, slash, dot or hash, that does not start with a
# less-than sign, and that has no white space at either end: the name goes into
# a shell word, a make recipe, the dovecot configuration and a Maildir++
# directory name.  A space inside the name is legal, so the templates put the
# name in single quotes.  Doveadm reads % and * as wildcards in a mailbox mask,
# and * and ? as wildcards in the mailbox key of a search query
# (doveadm-mailbox(1), doveadm-search-query(7)), so an alias with one of them
# would move and delete the mail of every folder that matches.  The dovecot
# configuration parser reads an unquoted value, so it takes a hash as the start
# of a comment, a leading less-than sign as the name of a file to include, and
# it trims white space.
my $FOLDER_NAME = q{\A(?![<\s])[^'"`%*?$\\\\/.#\r\n]+(?<!\s)\z};

sub args {
    my ($class) = @_;
    return (
        type       => 'object',
        properties => {
            names => {
                type                 => 'object',
                default              => {},
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{password gecos}],
                    properties => {
                        password => {
                            type       => 'string',
                            'x-secret' => 1,

                            # The template renders an Argon2id hash, so
                            # the payload never holds the plaintext.  A literal
                            # password stays in the configuration file, and
                            # bin/preflight says so.
                            description => 'The mailbox password.  Write it as a secret: reference; the value belongs in the store rather than in recipes.d.',
                        },
                        gecos => {
                            type    => 'string',
                            pattern => "$NO_COLON",

                            # The passwd-file has no way to quote a colon.
                            description => 'The full name of the account.  It cannot hold a colon or a line break.',
                        },

                        # The mailboxes that doveadm makes for this account,
                        # in addition to INBOX.
                        mailboxes => { type => 'array', items => { type => 'string', pattern => $FOLDER_NAME }, default => [] },

                        # The folders that sa_train_amavis learns as spam, in
                        # addition to the one with the \Junk special use.  No
                        # quote and no percent sign, because the name goes
                        # into a cron line and a shell word.
                        spam_folders => {
                            type        => 'array',
                            default     => [],
                            items       => { type => 'string', pattern => "$SPAM_FOLDER" },
                            description => 'Folders of this account, besides Junk Email, the one with the \Junk special use, that hold spam, for example INBOX.$spam.  The nightly training learns each as spam.  Every other folder of the account is learned as ham, but INBOX, Deleted Items, Drafts and Sent Items, which have the \Trash, \Drafts and \Sent special uses.',
                        },
                    },
                },
            },
            unlisted_accounts => {
                type        => 'string',
                enum        => [qw{refuse keep}],
                default     => 'refuse',
                description => 'What a build does with an account that the salvaged passwd-file holds and mail.names does not.  refuse stops the build and names the addresses.  keep copies their lines into the new passwd-file and names them in the setup log.',
            },

            # The default of each of the five is on the member, not on the map,
            # so that an operator who adds a translated name keeps the five.
            mailbox_aliases => {
                type        => 'object',
                default     => {},
                description =>
                  'Map from the name of a folder that a mail client makes to the folder that it reaches.  The mailbox_alias plugin of dovecot links the name to the folder, and the build moves the messages of a real folder under that name into the folder first.  A name that you add keeps the five that are there.  A name and a folder cannot hold a quote, a backtick, a percent sign, an asterisk, a question mark, a dollar sign, a backslash, a slash, a dot, a hash sign or a line break, cannot start with a less-than sign, and cannot start or end with white space.',
                additionalProperties => { type    => 'string', pattern => $FOLDER_NAME },
                propertyNames        => { pattern => $FOLDER_NAME },
                properties           => {
                    'Junk'             => { type => 'string', default => 'Junk Email',    pattern => $FOLDER_NAME },
                    'Sent'             => { type => 'string', default => 'Sent Items',    pattern => $FOLDER_NAME },
                    'Trash'            => { type => 'string', default => 'Deleted Items', pattern => $FOLDER_NAME },
                    'Sent Messages'    => { type => 'string', default => 'Sent Items',    pattern => $FOLDER_NAME },
                    'Deleted Messages' => { type => 'string', default => 'Deleted Items', pattern => $FOLDER_NAME },
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

            ipv6 => { type => 'boolean', default => 1 },

            trusted_clients => { $class->trusted_clients_arg },

            # No default, because it depends on the guest: enrich turns it on
            # where main_ip is a public address.  A default here would say one
            # thing for every guest.
            local_resolver => {
                type        => 'boolean',
                description => 'Whether SpamAssassin asks a recursive resolver on this guest (unbound) instead of the resolvers of the installation.  Unset, it is on where main_ip is a public address.  Set it to false to turn it off.',
            },
        },
    );
}

=head2 trusted_clients_arg

The schema of C<trusted_clients>, a new copy at each call.
L<Provisioner::Recipe::mailrelay> takes the same field.  See L</Trusted
clients>.

Returns the schema of the field, as a list of key and value pairs.

    my %field = Provisioner::Recipe::mail->trusted_clients_arg();

=cut

sub trusted_clients_arg {
    return (
        type        => 'array',
        default     => [],
        uniqueItems => 1,
        items       => { anyOf => [ { type => 'string', format => 'ipv4' }, { type => 'string', format => 'ipv6' } ] },
        description => 'The addresses of mail servers that skip the checks of the client and of the sender on port 25: reverse DNS, RBLs and the sender domain.  They still deliver only to the domains of this guest.  See "Trusted clients" in Provisioner::Recipe::mail.',
    );
}

=head2 $recipe->machine_wide(%opts)

C<trusted_clients>, as one string, because the global half writes the checks
of port 25 for the whole machine.  See L<Provisioner::Recipe/machine_wide>.

Returns C<trusted_clients> and the sorted addresses joined with commas, as a
list of one key and one value.

    my %settings = $recipe->machine_wide( trusted_clients => ['192.0.2.25'] );

=cut

sub machine_wide {
    my ( $self, %opts ) = @_;

    # bin/new_config compares each setting as a string.  The order of the list
    # does not change what postfix does.
    return ( trusted_clients => join( q{,}, sort @{ $opts{trusted_clients} // [] } ) );
}

=head2 $recipe->listens()

The ports of postfix: SMTP on 25, and submission on 465 over TLS and on 587,
on every address, and the return from amavis on 10025, on 127.0.0.1.  The
ports of dovecot, on every address: POP3 on 110 and 995, IMAP on 143 and 993.
C<postgrey> on 10023, on 127.0.0.1.  amavis on 10024 and C<spamd> on 783, both
on 127.0.0.1 and on ::1.  The C<proxied_ports>, on every address, which the
firewall closes to all but the mail relays.

ManageSieve on 4190, on 127.0.0.1, and on ::1 unless C<ipv6> is off.  A claim
on loopback opens nothing in the firewall, and dovecot binds the port on no
other address, so no client outside the guest reaches it.

Returns the claims, as a list.

    my @claims = $recipe->listens( ipv6 => 1 );

=cut

sub listens {
    my ( $self, %opts ) = @_;
    return (
        qw{25 465 587 110 995 143 993 127.0.0.1:10025 127.0.0.1:10023 127.0.0.1:4190},
        ( ( $opts{ipv6} // 1 ) ? '[::1]:4190' : () ),
        ( sort { $a <=> $b } values %{ { $self->proxied_ports } } ),
        map { ( "127.0.0.1:$_", "[::1]:$_" ) } 10024, 783
    );
}

=head2 proxied_ports

The port where this guest takes each service of the mail clients from a mail
relay, with the PROXY protocol: C<imaps>, C<submissions> and C<pop3s>.	See
L</Sending through a mail relay>.

Returns a map from each service to its port, as a list.

    my %ports = $recipe->proxied_ports();

=cut

sub proxied_ports {
    return ( imaps => 10993, submissions => 10465, pop3s => 10995 );
}

=head2 $recipe->jails()

The jails that fail2ban ships for postfix and dovecot.  They ban a host whose
logins to SMTP, IMAP or POP fail too often, and read both from the journal.
The dovecot jail allows ten matches.  L</The settings of a mail client> says
why.

Returns a map from each jail to its settings, as a list of names and hash
references.

    my %jails = $recipe->jails();

=cut

sub jails {
    return (
        postfix => {},
        dovecot => { maxretry => 10 },
    );
}

=head2 $recipe->subdomains()

C<mail>, which the MX names and the SRV records point at, and C<autodiscover>
and C<autoconfig>, which F<mail.autodiscover_vhost.tt> answers for so a client
can find its own settings.  That vhost is why this recipe requires nginx, and
it lists the two names in the C<sites> of nginx.

Returns the three names, as a list.

    my @names = $recipe->subdomains();

=cut

sub subdomains {
    return qw{mail autodiscover autoconfig};
}

=head2 $recipe->addressed_names(%opts)

C<mail.DOMAIN>, which the MX and most of the SRV records name, and
C<autodiscover.DOMAIN>, which the SRV record of Autodiscover names.  See
L<Provisioner::Recipe>.

Returns the two names, as a list.

    my @names = $recipe->addressed_names( domain => 'test.test' );

=cut

sub addressed_names {
    my ( $self, %opts ) = @_;
    return map { "$_.$opts{domain}" } qw{mail autodiscover};
}

=head2 $recipe->dns_records(%opts)

The MX of the domain, which names C<mail.DOMAIN>, its SPF and DMARC policies,
the records that point a mail client at its settings, an SRV record for each
port that a client sends or reads mail on, and C<dkim_records>.  See L<Provisioner::Recipe>.
The SPF policy passes the address of the domain and of its MX, which is the
address of a mail relay where the domain has one.

Returns the records, as a list of hash references.

    my @records = $recipe->dns_records( domain => 'test.test' );

=cut

sub dns_records {
    my ( $self, %opts ) = @_;
    my $domain = $opts{domain};
    my $mx     = "mail.$domain.";

    my %srv = ( imaps => 993, pop3s => 995, submissions => 465, submission => 587 );
    return (
        { type => 'MX',  name => $domain,                      content => "10 $mx" },
        { type => 'TXT', name => $domain,                      content => 'v=spf1 +a +mx -all',                                       match => 'v=spf1' },
        { type => 'TXT', name => "_dmarc.$domain",             content => 'v=DMARC1; p=none',                                         match => 'v=DMARC1' },
        { type => 'TXT', name => $domain,                      content => "mailconf=https://autoconfig.$domain/mail/config-v1.1.xml", match => 'mailconf=' },
        { type => 'SRV', name => "_autodiscover._tcp.$domain", content => "0 0 443 autodiscover.$domain.",                            match => q{} },
        ( map { { type => 'SRV', name => "_$_._tcp.$domain", content => "0 0 $srv{$_} $mx", match => q{} } } sort keys %srv ),
        $self->dkim_records($domain),
    );
}

=head2 dkim_key_ref(domain)

Where the secret store keeps the DKIM key of C<$domain>, which signs its
outbound mail.	See C<guest_secrets>.

=over 4

=item domain - Str - the mail domain

=back

Returns Str, the reference into the secret store.

    my $ref = $recipe->dkim_key_ref('test.test');

=cut

sub dkim_key_ref {
    my ( $self, $domain ) = @_;
    return "secret:mail/$domain-dkim-key/password";
}

=head2 dkim_records(domain)

The TXT record of the public half of the DKIM key of C<$domain>, once for each
selector of F<mail.opendkim-keytable.tt>, which names the key under both.  Its
match is C<v=DKIM1>, so that a new key replaces the old one.  None where
C<held> in L<Trog::Secrets> has no key, as in a run that opened no store.

=over 4

=item domain - Str - the mail domain

=back

Returns the records, as a list of hash references, or an empty list.

    my @records = $recipe->dkim_records('test.test');

=cut

sub dkim_records {
    my ( $self, $domain ) = @_;
    my $private = Trog::Secrets->held( $self->dkim_key_ref($domain) ) // return;

    my $public = MIME::Base64::encode_base64( Crypt::PK::RSA->new( \$private )->export_key_der('public'), q{} );
    my $record = "v=DKIM1; h=sha256; k=rsa; t=y; p=$public";
    return map { { type => 'TXT', name => "$_._domainkey.$domain", content => $record, match => 'v=DKIM1' } } qw{default mail};
}

=head2 $recipe->guest_secrets($install_dir, $domain)

The DKIM key of the domain, which opendkim signs with.  It comes from the
secret store, so a rebuild keeps it, and it never goes into the salvage of the
guest.  The store makes it the first time: an RSA key of 2048 bits.  It takes
no options.

=over 4

=item install_dir - Str - the install directory of the domain, which it does
not use

=item domain - Str - the mail domain

=back

Returns the path of the key on the guest and how to get it, as a list of a path
and a hash reference.

    my %files = $recipe->guest_secrets( '/path/to/install', 'test.test' );

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "/etc/opendkim/keys/$domain/default.private" => {
            ref      => $self->dkim_key_ref($domain),
            generate => sub {
                my $key = Crypt::PK::RSA->new;
                $key->generate_key( 256, 65537 );
                return $key->export_key_pem('private');
            },
            owner => 'opendkim:opendkim',
            mode  => '0600',
        },
    );
}

=head2 $recipe->sends_mail

True.  See L<Provisioner::Recipe>.

Returns a Bool, always true.

    my $bool = $recipe->sends_mail();

=cut

sub sends_mail {
    return 1;
}

=head2 $recipe->grants($domain, %opts)

When C<relay.host> is a mail relay of this installation, the login of
C<$domain> on that guest, as C<grants> in L<Provisioner::Recipe> says.  See
L</Sending through a mail relay>.

Dies when C<relay.host> is a guest of this installation that runs no
mailrelay, or when it runs mailrelay and C<relay.port> or C<relay.to> is set.

Returns the grant as a list of one hash reference, or an empty list.

    my @grants = $recipe->grants( 'test.test', relay => { host => 'relay.test.test' } );

=cut

# The guest of this installation that relay.host names, which runs mailrelay,
# or nothing when relay.host is a host outside.
my sub mailrelay_of ( $domain, %opts ) {
    my $host = ( $opts{relay} // {} )->{host};
    return unless Provisioner::Cookbook->configures($host);

    die "mail: $domain relays through $host, which is a guest of this installation but runs no mailrelay.  Give $host the mailrelay recipe, or relay through a host outside.\n"
      unless exists Provisioner::Cookbook->domain_config($host)->{mailrelay};
    die "mail: $domain relays through $host, which runs mailrelay and sets its own port, so relay.port and relay.to are for a host outside.  Remove them.\n"
      if defined $opts{relay}{port} || @{ $opts{relay}{to} // [] };
    return $host;
}

sub grants {
    my ( $self, $domain, %opts ) = @_;
    my $relay = mailrelay_of( $domain, %opts );
    return () unless defined $relay;
    return { recipe => 'mailrelay', guest => $relay, client => $domain };
}

=head2 $recipe->grant_terms($grant, %opts)

The address of the guest of the client of C<$grant>, where the mail relay sends
the mail of the domain that comes in from the internet.  Also the upstream of
each service of the mail clients, at that address and the port in
C<proxied_ports>, and the names that the clients ask for, which are the domain
and C<mail.DOMAIN>.  See L<Provisioner::Recipe::mailrelay/Mail in> and
L<Provisioner::Recipe::mailrelay/Mail clients>.

Dies when that guest has no address in the address pool.

Returns C<address>, C<upstreams> and C<names>, as a list of key and value pairs.

    my %terms = $recipe->grant_terms( { client => 'test.test', guest => 'relay.test.test' } );

=cut

sub grant_terms {
    my ( $self, $grant, %opts ) = @_;
    my $domain = $grant->{client};

    my ( $guest, $address ) = Provisioner::IPPool::guest_address($domain);
    die "mail: $grant->{guest} relays the mail of $domain to the address of $guest.  $guest has no address in " . Provisioner::IPPool::db_path() . ".\n"
      unless defined $address;
    my %port = $self->proxied_ports;
    return (
        address   => $address,
        upstreams => { map { $_ => "$address:$port{$_}" } keys %port },
        names     => [ $domain, "mail.$domain" ],
    );
}

=head2 $recipe->template_files(@recipes)

The configuration of postfix, dovecot, opendkim, opendmarc, amavis,
spamassassin and unbound, the files that tell a mail client its settings, and
the files for a mail relay.  It ignores C<@recipes>, the loaded recipes.

Returns a map from each template to the file that it renders or copies, as a list.

    my %files = $recipe->template_files();

=cut

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
        'mail.opendkim-removearfrom.tt'  => 'RemoveARFrom',
        'mail.opendmarc.tt'              => 'opendmarc.conf',
        'mail.opendmarc-ignorehosts.tt'  => 'ignore.hosts',
        'mail.postfix.master.tt'         => 'master.cf',
        'mail.postfix.main.global.tt'    => 'main.cf.global',
        'mail.postfix.main.tt'           => 'main.cf.domain',
        'mail.amavis.tt'                 => 'amavis.domain',
        'mail.amavis.global.tt'          => 'amavis.global',
        'mail.autodiscover.tt'           => 'autodiscover.xml',
        'mail.autoconfig.tt'             => 'config-v1.1.xml',
        'mail.autodiscover_vhost.tt'     => 'autodiscover_vhost',
        'mail.cron.tt'                   => 'mailcron',
        'mail.spamassassin.tt'           => 'mail_spamassassin.cf',
        'mail.unbound.tt'                => 'mail_unbound.conf',
        'mail.spamassassin-update.tt'    => 'mail_spamassassin_update.conf',
        'mail.junk.sieve'                => 'junk.sieve',
        'mail.mailrelay_tls_policy.tt'   => 'mailrelay_tls_policy',
        'mail.mailrelay_ufw.tt'          => 'mail_mailrelay_ufw.conf',
        'mail.mailrelay_jail.tt'         => 'mail_mailrelay.jail',
        'relay.action.tt'                => 'mail_relay.action',
        'mail.proxy_from.tt'             => 'mail_proxy_from',
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # The schema cannot say what a key of names may be.  Ask here, because the
    # template engine only warns when passwd_line dies, and renders no line.
    for my $key ( keys %{ $opts{names} // {} } ) { Provisioner::MailAccount::check_name($key); }

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

    $opts{sender_logins}  = \@logins;
    $opts{domain_aliases} = [ $self->domain_aliases(%opts) ];
    $opts{helo_name}      = Provisioner::Cookbook->helo_name_of( $opts{domain} );
    $opts{default_realm}  = Provisioner::Cookbook->machine_of( $opts{domain} ) eq $opts{domain} ? 1 : 0;
    $opts{proxied_ports}  = { $self->proxied_ports };

    # See "Asking blocklists from this guest" in the POD.
    $opts{local_resolver} //= Data::Validate::IP::is_public_ipv4( $opts{main_ip} ) ? 1 : 0;

    # The templates treat relay.host as a host outside unless mailrelay is set.
    $opts{mailrelay} = mailrelay_of( $opts{domain}, %opts );
    if ( defined $opts{mailrelay} ) {
        my $mailrelay = Provisioner::Cookbook->load('mailrelay');
        $opts{mailrelay_login} = {
            address  => Provisioner::IPPool::reachable_address( $opts{mailrelay} ),
            port     => $mailrelay->relay_port_of( $opts{mailrelay} ),
            password => $mailrelay->password_path( $opts{domain} ),
        };
        $opts{ban_relay}   = $mailrelay->ban_client( $opts{domain}, $opts{mailrelay_login}{address} );
        $opts{relay_jails} = [ sort keys %{ { $self->jails(%opts) } } ];
    }

    return %opts;
}

sub formatters {
    my ($class) = shift;
    return (
        dovecot_password_hash => Text::Xslate::html_builder( \&Provisioner::Utils::dovecot_password_hash ),

        # The line of the passwd-file, from the one place that knows it, which
        # bin/add_mail_user also calls.  html_builder, so that the hash and a
        # gecos with an ampersand are not escaped as HTML.
        mail_passwd_line => Text::Xslate::html_builder(
            sub {
                my ( $domain, $name, $gecos, $password ) = @_;
                return Provisioner::MailAccount::passwd_line( domain => $domain, name => $name, gecos => $gecos, password => $password );
            }
        ),

        # The lines of the two postfix tables, from the same place, so that
        # the tools write what a build writes.
        mail_sender_login_line => Text::Xslate::html_builder( \&Provisioner::MailAccount::sender_login_line ),
        mail_virtual_maps_line => Text::Xslate::html_builder( \&Provisioner::MailAccount::virtual_maps_line ),

        mail_virtual_aliases_line => Text::Xslate::html_builder( \&Provisioner::MailAccount::virtual_aliases_line ),
    );
}

sub datadirs {
    return ('.mail');
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    return ( "/mail/$domain" => { from => "$install_dir/$domain/mailnames", owner => 'dovecot:dovecot' } );
}

sub remote_files {
    my ( $class, $install_dir, $domain ) = @_;
    return ( "/mail/$domain" => 'mailnames' );
}

sub tests {
    return qw{mail.tt};
}

1;
