package Provisioner::Recipe::sshd;

#ABSTRACT: The ssh host key of a guest, from the secret store, so a rebuild keeps it.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Cookbook();
use Provisioner::Utils();

=head1 NAME

Provisioner::Recipe::sshd - the configuration of sshd on every guest: who logs
in, how, and the host key that it offers, the same after every rebuild.

=head1 SYNOPSIS

Nobody configures this recipe.  Every distro recipe requires it, so every guest
has it.  See L<Provisioner::DistroRecipe/required_recipes>.

=head1 DESCRIPTION

This recipe owns F</etc/ssh/sshd_config.d/10-provisioner.conf>, the drop-in
that every guest gets.  A recipe that adds to sshd, such as
L<Provisioner::Recipe::sssd> or a relay, installs a drop-in of its own.

=head2 No passwords

The drop-in sets C<PasswordAuthentication no> and C<PermitRootLogin
prohibit-password>.  So nobody logs in with a password.  Set up the users and
their keys in F<recipes.yaml> and in the F<users.yaml> of the data directory.
root logs in with a key only, which is how a backup reaches a guest.

sshd takes the first value that it reads for these options, and it reads the
drop-ins in lexical order.  cloud-init and the cloud image write
F<50-cloud-init.conf> and F<60-cloudimg-settings.conf>, and either can allow
passwords.  The name starts with C<10->, so this drop-in comes first and its
values win.

The makefile kept this policy in F<100-security.conf> before this recipe.  The
fragment removes that file, so a guest provisioned in place has one copy of the
policy.

=head2 The host key

A client of a guest pins its host key in F<known_hosts>.  cloud-init makes new
host keys on the first boot of each guest, so after a rebuild every client that
pinned the old key refuses the guest, with a warning that the host key changed.
A guest behind a relay pins the key of the relay with
C<StrictHostKeyChecking=yes>, so its bans stop.

So the ed25519 host key comes from the secret store.  C<guest_secrets> names
it, the store makes it once, and F<bin/provision> places it before the makefile
runs.  The global fragment then does three things:

=over 4

=item * It derives F</etc/ssh/ssh_host_ed25519_key.pub> from the private key
that was placed.  The public key that cloud-init wrote belongs to the key that
the placement replaced.

=item * The drop-in names that key as the only C<HostKey>.  sshd adds up
C<HostKey> lines, so the order of the drop-ins does not matter for this
option.  cloud-init still makes RSA and ECDSA keys,
and they are new on each build.  With a C<HostKey> line, sshd loads only the
keys that the configuration names, so a client never sees a key that changed.
The fast lane sshd of L<Provisioner::Recipe::sshfastlane> includes the main
configuration, so it offers the same key.

=item * It checks the configuration with F<scripts/check_sshd_config>, and
queues a reload of sshd, which then offers the placed key and refuses
passwords.

=back

The key belongs to the machine, not to a domain.  A tenant runs on the guest of
its host, so its key is the key of its host.  See C<host_key_ref>.

=head1 METHODS

=head2 $ref = $class->host_key_ref($domain)

The reference in the secret store of the host key of the guest that runs
C<$domain>: C<secret:ssh/MACHINE-host-key/password>, where MACHINE is
L<Provisioner::Cookbook/machine_of> C<$domain>.  So a tenant and its host name
one entry, and F<bin/provision> places the same key for both.

L<Provisioner::Cookbook/secret_references> asks this for each domain, because
no configuration names this recipe.

=cut

sub host_key_ref {
    my ( $class, $domain ) = @_;
    return 'secret:ssh/' . Provisioner::Cookbook->machine_of($domain) . '-host-key/password';
}

=head2 $ref = $class->relay_host_key_ref($domain)

The reference where the host key of a relay was before this recipe:
C<secret:relay/MACHINE-ssh-host-key/password>.  The generator of
C<guest_secrets> takes the key from there, so a relay keeps the key that the
guests behind it pinned.

=cut

sub relay_host_key_ref {
    my ( $class, $domain ) = @_;
    return 'secret:relay/' . Provisioner::Cookbook->machine_of($domain) . '-ssh-host-key/password';
}

=head2 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The private ed25519 host key of sshd, at F</etc/ssh/ssh_host_ed25519_key>,
from C<host_key_ref>.  When the store has no key there, the generator takes the
key at C<relay_host_key_ref>, and makes a new one only when that is empty too.
See L<Trog::Secrets/remember>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain ) = @_;

    my $former  = $self->relay_host_key_ref($domain);
    my $comment = 'root@' . Provisioner::Cookbook->machine_of($domain);
    return (
        '/etc/ssh/ssh_host_ed25519_key' => {
            ref      => $self->host_key_ref($domain),
            generate => sub ($stored) {
                return $stored->($former) // Provisioner::Utils::new_ssh_private_key( Ed25519 => 256, $comment );
            },
            owner => 'root:root',
            mode  => '0600',
        },
    );
}

sub template_files {
    return ( 'sshd.conf.tt' => 'sshd.conf' );
}

sub tests {
    return qw{sshd.tt};
}

1;
