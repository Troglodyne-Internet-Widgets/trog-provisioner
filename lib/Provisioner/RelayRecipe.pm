package Provisioner::RelayRecipe;

#ABSTRACT: Base class for a recipe that fronts other guests, and carries their bans.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';
no autovivification;

use File::Basename();

use Provisioner::Cookbook();

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::RelayRecipe - what a relay guest shares, whatever it relays

=head1 SYNOPSIS

    package Provisioner::Recipe::nginxrelay;
    use parent qw{Provisioner::RelayRecipe};

    sub relay_dir    { return '/etc/nginx/nginxrelay.d' }
    sub banned_ports { my ( $self, %opts ) = @_; return ( 80, $opts{tls_port} ) }
    sub registration_files { ... }    # the ban key, and what the relay registers

=head1 DESCRIPTION

A relay takes the connections of the internet for the guests behind it, which
register with it when they are built.  L<Provisioner::Recipe::nginxrelay> and
L<Provisioner::Recipe::mailrelay> are the two.  One guest can run both, so
what they share must work once on one guest:

=over 4

=item * The keys that the guests send their bans with, which sshd reads from
one directive.

=item * The C<stream> block of nginx, which nginx takes once.

=back

A subclass includes F<templates/files/relay.install.tt> in its fragment, which
installs them.

The guests behind a relay pin its ssh host key.  Every guest keeps that key
across a rebuild, because L<Provisioner::Recipe::sshd> places it from the secret
store.  C<issue_grant> hands out its public half.

=head2 Reboots

A relay reboots only by hand, because every guest behind it is offline while
it reboots.  So F<templates/files/relay.install.tt> installs a reboot check
that always holds the reboot, with the reason C<this guest reboots only by
hand>.  The relay still logs that it needs a reboot.  See Reboot checks in
L<Provisioner::Recipe>.

=head2 Bans

A guest behind a relay sees the address of each client, so its fail2ban finds
the abuse.  But a ban there blocks nothing, because the packets come from the
relay.  So the guest also sends each ban to the relay, and the relay drops the
address.

When the client script of the relay registers a domain, it issues the domain a
key, through C<issue_ban_key> in F<scripts/relay_files>.  The key runs only
F<scripts/relay_ban> for that domain, and only from the address of its guest.
C<relay_ban> adds the address to the ipset C<ban_set> for the time of the ban,
or removes it.  The keys are in C<relay_dir> with the registrations, so the
salvage of a rebuild keeps both.  The salvage also keeps the bans in force, in
C<ban_dir>.  See C<remote_files>.

F</etc/ufw/after.init.d/RECIPE-bans> drops every packet from an address in the
set to C<banned_ports>, each time ufw loads.  See
L<Provisioner::Recipe::ufw/Rules that ufw cannot write>.  ssh stays open to a
banned address, so a ban that a guest sends cannot lock the operator out of the
relay.  When ufw unloads, the set goes to F</var/lib/RECIPE-bans/saved> with
the time that each ban has left, and it comes back when ufw loads.

Each relay has a set of its own.  So a ban that a guest sends to one relay
drops the address only on the ports of that relay.

=head2 Ports of the guests

Besides the ports that a relay always serves, a guest can register ports of
its own, each for some of its names, each name mapped to a port of the guest.
The relay passes such a port, by the SNI name and with the PROXY protocol,
only for the names that registered it, and listens there only while a guest
does.  The client script
of the relay writes the registration into C<relay_dir>, through
C<write_ports> in F<scripts/relay_files>, which has the whole account.  The
C<stream> block includes the server of each port from there.

The same hook as the bans, F</etc/ufw/after.init.d/RECIPE-bans>, opens each
of these ports in the firewall each time ufw loads, and again when the client
runs it with C<ports> after a registration or a release.  A banned address is
dropped there too, and each address has a limit of C<port_rate_limit> new
connections a second on each port.  The relay may connect out to the address
and the port of each guest that registered one.

The salvage of C<relay_dir> keeps the registrations, so a rebuilt relay
listens on the same ports.

=head1 METHODS

=head2 $dir = $recipe->relay_dir()

The directory of the registrations, and of the keys that the relay issued.  A
subclass must say.

Takes no arguments.

Returns Str, the directory, from a subclass.  This class dies, and names the
class, which does not say.

    my $dir = Provisioner::Recipe::nginxrelay->relay_dir;

=cut

sub relay_dir {
    my ($self) = @_;
    die ref($self) || $self, " is a relay, so it must say where its registrations are\n";
}

=head2 @ports = $recipe->banned_ports(%opts)

The ports where the relay drops the packets of a banned address.  A subclass
must say.

=over 4

=item opts - HASH - the configuration of the recipe for the domain

=back

Returns a list of Int, the ports, from a subclass.  This class dies, and names
the class, which does not say.

    my @ports = $recipe->banned_ports(%config);

=cut

sub banned_ports {
    my ($self) = @_;
    die ref($self) || $self, " is a relay, so it must say which ports a ban closes\n";
}

=head2 $hits = $recipe->port_rate_limit()

How many new connections an address may open each second on each port that a
guest registered.  See L</Ports of the guests>.

Takes no arguments.

Returns Int, the connections a second.

    my $hits = $recipe->port_rate_limit;    # 1024

=cut

sub port_rate_limit {
    return 1024;
}

=head2 @args = port_args($routes)

The arguments of the client script of a relay for C<%routes>, which maps each
port of its own to each name that passes on it, mapped to the port of the
guest: a C<--port> and a C<PORT=GUEST_PORT:NAME,...> for each port and port of
the guest, in order.  See L</Ports of the guests>.

A function, not a method.

=over 4

=item routes - HashRef[HashRef[Int]] - from each port of the relay, to each name, to the port of the guest

=back

Returns a list of Str, the arguments.

    my @args = Provisioner::RelayRecipe::port_args( { 8448 => { 'chat.test.test' => 8448 } } );
    # ( '--port', '8448=8448:chat.test.test' )

=cut

sub port_args {
    my ($routes) = @_;
    my @args;
    foreach my $port ( sort { $a <=> $b } keys %$routes ) {
        my %names_of;
        push( @{ $names_of{ $routes->{$port}{$_} } }, $_ ) foreach sort keys %{ $routes->{$port} };
        push( @args,                                  map { ( '--port', "$port=$_:" . join( q{,}, @{ $names_of{$_} } ) ) } sort { $a <=> $b } keys %names_of );
    }
    return @args;
}

=head2 $set = $recipe->ban_set()

The name of the ipset of the bans of this relay: the name of the recipe, and
C<-bans>.

Takes no arguments.

Returns Str, the name of the set.

    my $set = Provisioner::Recipe::nginxrelay->ban_set;    # 'nginxrelay-bans'

=cut

sub ban_set {
    my ($self) = @_;
    return $self->recipe_name . '-bans';
}

=head2 $dir = $recipe->ban_dir()

The directory where the hook of the bans saves C<ban_set>, with the time that
each ban has left: F</var/lib/> and the name of the set.

Takes no arguments.

Returns Str, the directory.

    my $dir = Provisioner::Recipe::nginxrelay->ban_dir;    # '/var/lib/nginxrelay-bans'

=cut

sub ban_dir {
    my ($self) = @_;
    return '/var/lib/' . $self->ban_set;
}

=head2 $path = $recipe->ban_hook()

The hook of the bans in F</etc/ufw/after.init.d>, which loads C<ban_set> into
the firewall when ufw loads, and saves it to C<ban_dir> when ufw unloads, or
when it is run with C<save>.

Takes no arguments.

Returns Str, the path of the hook.

    my $hook = Provisioner::Recipe::nginxrelay->ban_hook;

=cut

sub ban_hook {
    my ($self) = @_;
    return '/etc/ufw/after.init.d/' . $self->ban_set;
}

=head2 %path_map = $recipe->remote_files()

C<relay_dir>, which holds the registrations and the keys that the relay issued,
and C<ban_dir>, which holds the bans in force.  Without the first, a rebuilt
relay serves no guest behind it until each one is built again.  Without the
second, an address that a guest banned connects again until it offends again,
because a guest sends a ban only when it bans.

It takes the C<$install_dir> and C<$domain> that L<Provisioner::Recipe/remote_files>
describes, and reads neither.

Returns a list of pairs of Str, from each directory on the relay to where it
lands.

    my %path_map = $recipe->remote_files;

=cut

sub remote_files {
    my ($self) = @_;
    return (
        $self->relay_dir . '/' => File::Basename::basename( $self->relay_dir ) . '/',
        $self->ban_dir . '/'   => $self->ban_set . '/',
    );
}

=head2 @commands = $recipe->remote_prepare()

Runs C<ban_hook> with C<save>, so that the salvage holds the bans in force
now, and not those of the last time that ufw unloaded.

It takes the C<$install_dir> and C<$domain> that L<Provisioner::Recipe/remote_prepare>
describes, and reads neither.

Returns a list of Str, the one command.

    my @commands = $recipe->remote_prepare;

=cut

sub remote_prepare {
    my ($self) = @_;
    return ( $self->ban_hook . ' save' );
}

=head2 %restores = $recipe->restores(%opts)

The salvage of C<relay_dir> and of C<ban_dir> goes back where it came from.

=over 4

=item install_dir - Str - where the files of domains live on the guest

=item domain - Str - the domain

=back

Returns a list of pairs, from each directory on the relay to a HashRef, as
L<Provisioner::Recipe/restores> describes it.

    my %restores = $recipe->restores( install_dir => '/opt/domains', domain => 'relay.test.test' );

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};
    return (
        $self->relay_dir => { from => "$install_dir/$domain/" . File::Basename::basename( $self->relay_dir ), owner => 'root:root' },
        $self->ban_dir   => { from => "$install_dir/$domain/" . $self->ban_set, owner => 'root:root', mode => '0700' },
    );
}

=head2 $path = $recipe->key_path($domain)

Where the ban key that this relay issues for C<$domain> is, on the guest of
C<$domain>, in base64.

=over 4

=item domain - Str - the domain of the guest

=back

Returns Str, the path.

    my $path = $recipe->key_path('web.test.test');

=cut

sub key_path {
    my ( $self, $domain ) = @_;
    return '/etc/fail2ban/' . $self->recipe_name . "/$domain.key.b64";
}

=head2 $path = $recipe->host_key_path($domain)

Where the public host key of the relay is, on the guest of C<$domain>, in
base64.

=over 4

=item domain - Str - the domain of the guest

=back

Returns Str, the path.

    my $path = $recipe->host_key_path('web.test.test');

=cut

sub host_key_path {
    my ( $self, $domain ) = @_;
    return '/etc/fail2ban/' . $self->recipe_name . "/$domain.host.b64";
}

=head2 \%ban = $recipe->ban_client($domain, $address)

What the guest of C<$domain> needs to send its bans to this relay, which it
reaches at C<$address>.  F<templates/files/relay.action.tt> and
F<templates/files/relay.client.tt> render it.  The keys are what
C<issue_grant> placed:

=over 4

=item * C<action>: the name of the action of fail2ban, the name of the recipe
and C<-DOMAIN>.

=item * C<address>: C<$address>.

=item * C<key_b64> and C<host_b64>: C<key_path> and C<host_key_path>.

=item * C<key> and C<known_hosts>: where the guest decodes the key, and pins the
host key.

=back

=over 4

=item domain - Str - the domain of the guest

=item address - Str - the address that the guest reaches the relay at

=back

Returns HashRef, with the keys above.

    my $ban = $recipe->ban_client( 'web.test.test', '192.0.2.10' );

=cut

sub ban_client {
    my ( $self, $domain, $address ) = @_;
    my $dir = '/etc/fail2ban/' . $self->recipe_name;
    return {
        action      => $self->recipe_name . "-$domain",
        address     => $address,
        key_b64     => $self->key_path($domain),
        key         => "$dir/$domain.key",
        host_b64    => $self->host_key_path($domain),
        known_hosts => "$dir/$domain.known_hosts",
    };
}

=head2 %files = $recipe->registration_files($grant, %terms)

The files that the relay issues when it registers the client of C<$grant>, as
C<issue_grant> in L<Provisioner::Recipe> says, one of which is the ban key at
C<key_path>.  A subclass must say.

=over 4

=item grant - HashRef - the grant, as L<Provisioner::Recipe/grants> describes it

=item terms - HASH - the terms of the grant

=back

Returns a list of pairs, as L<Provisioner::Recipe/issue_grant> describes them,
from a subclass.  This class dies, and names the class, which does not say.

    my %files = $recipe->registration_files( $grant, %terms );

=cut

sub registration_files {
    my ($self) = @_;
    die ref($self) || $self, " is a relay, so it must say what it issues to a guest that registers\n";
}

=head2 %files = $recipe->issue_grant($grant, %terms)

C<registration_files>, and the public host key of the relay at C<host_key_path>
of the client, as C<issue_grant> in L<Provisioner::Recipe> says.  The client
pins the host key, so that a ban never goes to a guest that only claims to be
the relay.

=over 4

=item grant - HashRef - the grant, with C<client> and C<guest>

=item terms - HASH - the terms of the grant

=back

Returns a list of pairs, from each path on the guest of the client to a
HashRef.  Dies as C<registration_files> does in a subclass that does not say.

    my %files = $recipe->issue_grant( { recipe => 'nginxrelay', guest => 'relay.test.test', client => 'web.test.test' } );

=cut

sub issue_grant {
    my ( $self, $grant, %terms ) = @_;
    return (
        $self->registration_files( $grant, %terms ),
        $self->host_key_path( $grant->{client} ) => {
            issue => { guest => $grant->{guest}, command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
            owner => 'root:root',
            mode  => '0644',
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds what F<templates/files/relay.install.tt> renders: C<relay_name>, C<ban_set>,
C<ban_dir>, C<ban_hook>, C<banned_ports>, C<relay_dir>, C<port_rate_limit>, and
C<relay_dirs>, the
C<relay_dir> of each relay in C<modules>.  sshd reads the keys of all of them
from one directive, and the C<stream> block includes the ports of the guests
from each.  A subclass that has an C<enrich> of its own calls this one.

=over 4

=item opts - HASH - the configuration, validated, with C<modules>

=back

Returns a list of pairs, C<%opts> with what is above.  Dies as C<relay_dir> and
C<banned_ports> do in a subclass that does not say.

    my %vars = $recipe->enrich(%opts);

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{relay_name}      = $self->recipe_name;
    $opts{ban_set}         = $self->ban_set;
    $opts{ban_dir}         = $self->ban_dir;
    $opts{ban_hook}        = $self->ban_hook;
    $opts{banned_ports}    = [ $self->banned_ports(%opts) ];
    $opts{relay_dir}       = $self->relay_dir;
    $opts{port_rate_limit} = $self->port_rate_limit;

    my @relays = grep { $_->isa(__PACKAGE__) } map { local ($_) = $_; Provisioner::Cookbook->load($_) } grep { local ($_) = $_; $_ ne $self->recipe_name } @{ $opts{modules} // [] };
    $opts{relay_dirs} = [ sort map { local ($_) = $_; $_->relay_dir } $self, @relays ];
    return %opts;
}

=head2 %files = $recipe->template_files()

The files that F<templates/files/relay.install.tt> installs.  A subclass adds
its own to these.

Takes no arguments here, and ignores the recipes that
L<Provisioner::Recipe/template_files> passes.

Returns a list of pairs of Str, from each template to the file that it renders.

    my %files = $recipe->template_files;

=cut

sub template_files {
    my ($self) = @_;
    return (
        'relay.sshd.tt'         => 'relay.sshd.conf',
        'relay.stream.conf.tt'  => 'relay.stream.conf',
        'relay.bans.tt'         => $self->recipe_name . '.bans',
        'relay.reboot-check.tt' => 'relay.reboot-check',
    );
}

1;
