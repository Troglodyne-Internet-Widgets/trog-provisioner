package Provisioner::Recipe::edge;

#ABSTRACT: Proxy the public names of other guests to them, by name.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Slurper();
use File::Temp();

use Provisioner::Cookbook();
use Provisioner::IPPool();
use Provisioner::Utils();
use Provisioner::Vars();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::edge

=head2 SYNOPSIS

    edge.somedomain:
        edge:

    internal.somedomain:
        nginx:
            edge: edge.somedomain
            public_names:
                shop.internal.somedomain: internal.somedomain

=head2 DESCRIPTION

Makes this guest the front of the guests that name it as their C<edge>, for
the internet.  The public names of those guests point at this guest.

A TLS connection on 443 goes to the guest that registered its SNI name, on its
port 8443, with the PROXY protocol.  The connection stays encrypted, so the
guest keeps its own certificate, and this guest holds no key of it.  A request
on 80 goes to the guest that registered its C<Host> header, on its port 8080,
with the address of the client in C<X-Forwarded-For>.  From outside, a name
that no guest registered gets no reply, except a name of a vhost of this guest
on 80.  See L</Ports>.

See L<Provisioner::Recipe::nginx/Names that reach the guest through a proxy>
for what the guest does on those ports.

=head2 Registration

Nothing in the configuration of this guest names the guests behind it.  Each
guest registers its own names when it is built, through C<edge_client
register>, which C<bin/provision> runs here as root.  C<bin/destroy> runs
C<edge_client release> when the guest goes away.  See F<scripts/edge_client>.

So this guest is built first, and a guest that names it fails to build while it
is down.  A rebuild of this guest does not need the guests behind it, because
the registrations in F</etc/nginx/edge.d> are salvaged.

Two guests cannot register one name.  The second one fails to build, and the
error names the domain that holds it.

=head2 Bans

A guest behind this edge sees the address of each client, so its fail2ban
finds the abuse.  But a ban there blocks nothing, because the packets come from
this guest.  So the guest also sends each ban here, and this guest drops the
address.  See L<Provisioner::Recipe::nginx/Bans through the edge>.

When C<edge_client register> issues the key of a domain, it authorizes the key
for root in F</etc/nginx/edge.d/authorized_keys.root>, which sshd reads beside
the keys of root.  The key runs only F<scripts/edge_ban> for that domain, and
only from the address of its guest.  C<edge_ban> adds the address to the ipset
C<edge-bans> for the time of the ban, or removes it.  The registrations and
their keys are salvaged together, so a rebuild keeps both.

F</etc/ufw/after.init.d/edge-bans> drops every packet from an address in the
set to port 80 and to C<tls_port>, each time ufw loads.  See
L<Provisioner::Recipe::ufw/Rules that ufw cannot write>.  ssh stays open to a
banned address, so a ban that a guest sends cannot lock the operator out of
the edge.  When ufw unloads, the set goes to F</var/lib/edge-bans/saved> with
the time that each ban has left, and it comes back when ufw loads.

The guests pin the ed25519 host key of this guest, so it comes from the secret
store, and a rebuild keeps it.

=head2 Mail out

A guest whose C<mail> names this guest as its C<edge> sends all the mail of its
domain out through the relay here.  The office cannot send on port 25, and the
reverse DNS and the SPF of the domain can name this guest.  See
L<Provisioner::Recipe::mail/Sending through an edge guest>.

When the guest is built, C<edge_client register-mail> makes a login for its
domain, with a new password that it prints and does not keep.  The guest
places the password as a grant.  F</etc/nginx/edge.d> keeps the hash, for
dovecot, which checks the logins for postfix and does nothing else.  It also
keeps the senders that each login owns, which is every address in its domain.
So a guest cannot send as another domain through this relay.

The relay is postfix on C<relay_port>, bound to the address that C<address> returns,
where the guests reach this guest, and not to the public address.  It takes
mail only over TLS, only from a login, and only with a sender that the login
owns.  It then delivers the mail itself, on port 25.  C<bin/destroy> runs
C<edge_client release-mail>, which removes the login.

=head2 Mail in

The registration of L</Mail out> also makes this guest take the mail of the
domain from the internet, on 25, and relay it to the guest of the domain over
the tunnel.  C<edge_client register-mail> gets the address of that guest from
the grant, and writes the domain into C<relay_domains>, its route into
C<transport_maps>, and C<@domain> into C<relay_recipient_maps>.  The guest
delivers any address of its domain to its catchall, so the edge takes every
recipient there.  Mail for any other domain is refused.

The edge makes the checks that a mail guest makes of a client: reverse DNS,
RBLs and C<HELO>, from F<templates/files/postfix.smtpd_restrictions.tt>, which
both include.  The guest then trusts the address of the edge, because only the
edge knows who the client was.  fail2ban bans here an address that fails too
often.  The reverse DNS of the public address of this guest must name it, or
the receivers of what it sends will refuse it.

=head2 SPF

The guest behind the edge sees the edge as the client of every message that
comes in, so only the edge can check the SPF of the sender.  On 25, before the
message:

=over 4

=item * The SPF policy service, C<policyd-spf>, refuses a sender that fails
SPF.  It adds nothing to the message.

=item * opendkim verifies the signatures, and signs nothing.  It removes every
C<Authentication-Results> under the name of this guest that the message
brought in, because the guests behind the edge trust that name.  Without it, a
client could write a pass of its own under that name.

=item * opendmarc then checks SPF against the client, and writes its verdicts
under the name of this guest.

=back

The opendmarc of the guest trusts that name, and takes the SPF verdict of the
edge for DMARC.  It checks DKIM itself, which does not depend on the client.
See L<Provisioner::Recipe::mail/Sending through an edge guest>.  The relay for
the mail of the guests runs neither, because that mail is theirs.

=head2 Ports
=head2 Ports

The stream proxy listens on C<tls_port>, and ufw forwards 443 there for every
connection that reaches the guest from outside.  A connection that the guest
makes to itself is not forwarded.  So nginx can still serve the vhosts of this
guest on 443 locally, such as the vhost that the letsencrypt guest test asks
for its certificate.  From outside, a name that no guest registered gets no TLS
handshake, the names of this guest included.

On 80, the server of this recipe is the default server of nginx.  A vhost of
this guest on 80 still answers for its own names, because nginx chooses among
the servers of one port by the C<Host> header.  This recipe takes the default
site of the nginx package away, which would be a second default server.

=cut

sub args {
    return (
        properties => {
            tls_port => {
                type        => 'integer',
                minimum     => 1024,
                maximum     => 65535,
                default     => 4443,
                description => 'The port of the stream proxy, where ufw forwards 443 from outside.  See "Ports".',
            },
            relay_port => {
                type        => 'integer',
                minimum     => 1024,
                maximum     => 65535,
                default     => 2587,
                description => 'The port of the relay that the guests behind this edge send their mail through.  See "Mail out".',
            },
        },
    );
}

# Defaulted here as well as in args, because required_recipes and rate_limits
# run before validation.
my sub tls_port (%opts) {
    return $opts{tls_port} // 4443;
}

my sub relay_port (%opts) {
    return $opts{relay_port} // 2587;
}

sub required_recipes {
    return (
        configd     => sub { return ( languages           => [qw{postfix opendkim opendmarc}] ) },
        letsencrypt => sub { return ( certificate_readers => ['postfix'] ) },
        nginx       => sub { return () },
        ufw         => sub {
            my (%opts) = @_;
            return ( port_forwards => [ { from => 443, to => tls_port(%opts) } ] );
        },
    );
}

=head2 %limits = $recipe->rate_limits(%opts)

The limit of 443 for C<tls_port>, because the forward happens before the limit
counts a connection.  The limit of a port of mail for C<relay_port>, and for
25, where the mail of the guests comes in.

=cut

sub rate_limits {
    my ( $self, %opts ) = @_;
    return ( tls_port(%opts) => 1024, relay_port(%opts) => 64, 25 => 64 );
}

=head2 %jails = $recipe->jails()

The jail that fail2ban ships for postfix, because the edge takes mail from the
internet on 25.  It bans here, where the client connects.

=cut

sub jails {
    return ( postfix => {} );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<relay_address>, the address that C<address> returns, where the relay
listens, and C<helo_name>, which is C<helo_name_of> in L<Provisioner::Cookbook>.
That is the name of the machine, which the A record of the edge names, unless
the machine runs L<Provisioner::Recipe::mail> too.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{relay_address} = $self->address( $opts{domain} );
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

=head2 $port = $recipe->relay_port_of($edge)

The C<relay_port> of the edge C<$edge>, from its configuration, or the default
when it sets none.

=cut

sub relay_port_of {
    my ( $self, $edge ) = @_;
    return relay_port( %{ Provisioner::Cookbook->domain_config($edge)->{edge} // {} } );
}

=head2 %path_map = $recipe->remote_files($install_dir, $domain)

F</etc/nginx/edge.d>, which holds the registrations.  Without it, a rebuilt
edge proxies nothing until each guest behind it is built again.

=cut

sub remote_files {
    return ( '/etc/nginx/edge.d/' => 'edge.d/' );
}

=head2 %restores = $recipe->restores(%opts)

The salvage of F</etc/nginx/edge.d> goes back there.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return ( '/etc/nginx/edge.d' => { from => "$install_dir/$domain/edge.d", owner => 'root:root' } );
}

=head2 $path = $recipe->key_path($domain)

Where the key that this guest issues for C<$domain> is, on the guest of
C<$domain>.

=cut

sub key_path {
    my ( $self, $domain ) = @_;
    return "/etc/fail2ban/edge/$domain.key.b64";
}

=head2 $path = $recipe->host_key_path($domain)

Where the public host key of the edge is, on the guest of C<$domain>, in
base64.

=cut

sub host_key_path {
    my ( $self, $domain ) = @_;
    return "/etc/fail2ban/edge/$domain.host.b64";
}

=head2 $path = $recipe->relay_password_path($domain)

Where the password of the relay that this guest issues for C<$domain> is, on
the guest of C<$domain>.

=cut

sub relay_password_path {
    my ( $self, $domain ) = @_;
    return "/etc/postfix/edge/$domain.password";
}

=head2 $address = $recipe->address($edge)

The address at which the guests reach the guest C<$edge>: its address in a bin
other than C<guests> of the address pool, which is the tunnel of an edge that
is a client of the VPN, and otherwise its address in C<guests>.  Dies when it
has neither, or more than one of the first kind.

=cut

sub address {
    my ( $self, $edge ) = @_;
    my $held = Provisioner::IPPool::holdings($edge);
    my @vpn  = grep { $_ ne $Provisioner::IPPool::GUESTS } sort keys %$held;

    die "edge: $edge has an address in each of " . join( ', ', @vpn ) . ", so the guests behind it cannot tell which one reaches it.\n" if @vpn > 1;
    my $address = @vpn ? $held->{ $vpn[0] } : $held->{$Provisioner::IPPool::GUESTS};
    die "edge: $edge has no address in " . Provisioner::IPPool::db_path() . ", so the guests behind it cannot send it their bans.\n" unless defined $address;
    return $address;
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The ed25519 host key of sshd, which the guests behind this edge pin.  See
L</Bans>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/etc/ssh/ssh_host_ed25519_key' => {
            ref      => "secret:edge/$domain-ssh-host-key/password",
            generate => sub {
                my $path = File::Temp::tempdir( CLEANUP => 1 ) . '/host_key';
                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => 256, "root\@$domain" );

                # bin/provision adds a newline, and ssh-keygen refuses a key
                # that ends with a blank line.
                chomp( my $key = File::Slurper::read_binary($path) );
                return $key;
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

=head2 %files = $recipe->issue_grant($grant, %terms)

For a grant with C<< service => 'mail' >>, the password of the relay that the
edge issues for the client of C<$grant>, at C<relay_password_path> of the
client.  C<%terms> has C<< address => $address >>, where the edge relays the
mail of the client that comes in.  See L</Mail out> and L</Mail in>.

For any other grant, the key that the edge issues when it registers the names
of the client of C<$grant>, at C<key_path> of the client, as C<issue_grant> in
L<Provisioner::Recipe> says.  Also the public host key of the edge, at
C<host_key_path>, which the client pins.  C<%terms> has
C<< upstreams => { tls => $tls, http => $http } >> and
C<< names => \@names >>.

The command is F<scripts/edge_client> C<register>, which root runs on the edge.
C<$tls> and C<$http> are each an IPv4 address and a port, where the edge sends
TLS and plain HTTP for C<@names>.  See L</Registration>.

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    my $client = $grant->{client};

    if ( ( $grant->{service} // q{} ) eq 'mail' ) {
        return (
            $self->relay_password_path($client) => {
                issue => { guest => $grant->{guest}, command => "$Provisioner::Vars::SCRIPT_DIR/edge_client register-mail $client $terms{address}" },
                owner => 'root:root',
                mode  => '0600',
            },
        );
    }

    return (
        $self->key_path($client) => {
            issue => {
                guest   => $grant->{guest},
                command => join( q{ }, "$Provisioner::Vars::SCRIPT_DIR/edge_client register", $client, @{ $terms{upstreams} }{qw{tls http}}, @{ $terms{names} } ),
            },
            owner => 'root:root',
            mode  => '0600',
        },
        $self->host_key_path($client) => {
            issue => { guest => $grant->{guest}, command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
            owner => 'root:root',
            mode  => '0644',
        },
    );
}

=head2 %revocation = $recipe->revoke_grant($grant)

For a mail grant, the removal of the relay login of the client of C<$grant>,
by F<scripts/edge_client> C<release-mail>.  For any other, the release of the
names of the client of C<$grant>, by F<scripts/edge_client> C<release>, as C<revoke_grant> in L<Provisioner::Recipe> says.  If the edge is
not up, the revocation says to run the command there by hand before another
guest gets the address, because the edge sends the names to whatever answers at
it.

=cut

sub revoke_grant {
    my ( $self, $grant ) = @_;
    my $client = $grant->{client};

    if ( ( $grant->{service} // q{} ) eq 'mail' ) {
        my $command = "$Provisioner::Vars::SCRIPT_DIR/edge_client release-mail $client";
        return (
            command => $command,
            doing   => "remove the relay login of $client",
            done    => "Removed the relay login of $client",
            stays   => "its relay still takes mail from the login of $client.  Run $command there",
        );
    }

    my $command = "$Provisioner::Vars::SCRIPT_DIR/edge_client release $client";
    return (
        command => $command,
        doing   => "release the public names of $client",
        done    => "Released the public names of $client",
        stays   => "it still sends the public names of $client to its old address.  Run $command there before another guest gets the address",
    );
}

sub template_files {
    return (
        'edge.stream.conf.tt'    => 'edge.stream.conf',
        'edge.http.conf.tt'      => 'edge.http.conf',
        'edge.ufw.conf.tt'       => 'edge_ufw.conf',
        'edge.sshd.tt'           => 'edge.sshd.conf',
        'edge.bans.tt'           => 'edge.bans',
        'edge.postfix.main.tt'   => 'edge.postfix.main',
        'edge.postfix.master.tt' => 'edge.postfix.master',
        'edge.dovecot.tt'        => 'edge.dovecot.conf',
        'edge.policyd_spf.tt'    => 'edge.policyd_spf',
        'edge.opendkim.tt'       => 'edge.opendkim.conf',
        'edge.opendmarc.tt'      => 'edge.opendmarc.conf',
    );
}

sub tests {
    return qw{edge.tt};
}

1;
