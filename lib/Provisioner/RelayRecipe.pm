package Provisioner::RelayRecipe;

#ABSTRACT: Base class for a recipe that fronts other guests, and carries their bans.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Slurper();
use File::Temp();

use Provisioner::Cookbook();
use Provisioner::Utils();

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

=item * The ssh host key, which the guests behind the relay pin.

=item * The keys that the guests send their bans with, which sshd reads from
one directive.

=item * The C<stream> block of nginx, which nginx takes once.

=back

A subclass includes F<templates/files/relay.install.tt> in its fragment, which
installs them.

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
salvage of a rebuild keeps both.

F</etc/ufw/after.init.d/RECIPE-bans> drops every packet from an address in the
set to C<banned_ports>, each time ufw loads.  See
L<Provisioner::Recipe::ufw/Rules that ufw cannot write>.  ssh stays open to a
banned address, so a ban that a guest sends cannot lock the operator out of the
relay.  When ufw unloads, the set goes to F</var/lib/RECIPE-bans/saved> with
the time that each ban has left, and it comes back when ufw loads.

Each relay has a set of its own.  So a ban that a guest sends to one relay
drops the address only on the ports of that relay.

=head1 METHODS

=head2 $dir = $recipe->relay_dir()

The directory of the registrations, and of the keys that the relay issued.  A
subclass must say.

=cut

sub relay_dir {
    my ($self) = @_;
    die ref($self) || $self, " is a relay, so it must say where its registrations are\n";
}

=head2 @ports = $recipe->banned_ports(%opts)

The ports where the relay drops the packets of a banned address.  A subclass
must say.

=cut

sub banned_ports {
    my ($self) = @_;
    die ref($self) || $self, " is a relay, so it must say which ports a ban closes\n";
}

=head2 $set = $recipe->ban_set()

The name of the ipset of the bans of this relay: the name of the recipe, and
C<-bans>.

=cut

sub ban_set {
    my ($self) = @_;
    return $self->recipe_name . '-bans';
}

=head2 $path = $recipe->key_path($domain)

Where the ban key that this relay issues for C<$domain> is, on the guest of
C<$domain>, in base64.

=cut

sub key_path {
    my ( $self, $domain ) = @_;
    return '/etc/fail2ban/' . $self->recipe_name . "/$domain.key.b64";
}

=head2 $path = $recipe->host_key_path($domain)

Where the public host key of the relay is, on the guest of C<$domain>, in
base64.

=cut

sub host_key_path {
    my ( $self, $domain ) = @_;
    return '/etc/fail2ban/' . $self->recipe_name . "/$domain.host.b64";
}

=head2 %files = $recipe->registration_files($grant, %terms)

The files that the relay issues when it registers the client of C<$grant>, as
C<issue_grant> in L<Provisioner::Recipe> says, one of which is the ban key at
C<key_path>.  A subclass must say.

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

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The ed25519 host key of sshd, which the guests behind the relay pin.  It comes
from the secret store, so a rebuild keeps it.  Every relay names the same entry,
so a guest that runs two relays has one key.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/etc/ssh/ssh_host_ed25519_key' => {
            ref      => "secret:relay/$domain-ssh-host-key/password",
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

=head2 %opts = $recipe->enrich(%opts)

Adds what F<templates/files/relay.install.tt> renders: C<relay_name>, C<ban_set>,
C<banned_ports>, and C<relay_dirs>, the C<relay_dir> of each relay in
C<modules>.  sshd reads the keys of all of them from one directive.  A subclass
that has an C<enrich> of its own calls this one.

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{relay_name}   = $self->recipe_name;
    $opts{ban_set}      = $self->ban_set;
    $opts{banned_ports} = [ $self->banned_ports(%opts) ];

    my @relays = grep { $_->isa(__PACKAGE__) } map { Provisioner::Cookbook->load($_) } grep { $_ ne $self->recipe_name } @{ $opts{modules} // [] };
    $opts{relay_dirs} = [ sort map { $_->relay_dir } $self, @relays ];
    return %opts;
}

=head2 %files = $recipe->template_files()

The files that F<templates/files/relay.install.tt> installs.  A subclass adds
its own to these.

=cut

sub template_files {
    my ($self) = @_;
    return (
        'relay.sshd.tt'        => 'relay.sshd.conf',
        'relay.stream.conf.tt' => 'relay.stream.conf',
        'relay.bans.tt'        => $self->recipe_name . '.bans',
    );
}

1;
