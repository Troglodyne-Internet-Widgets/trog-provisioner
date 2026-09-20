package Provisioner::Recipe::git;

#ABSTRACT: Give an account on the guest an identity that git pushes and signs with.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Slurper();
use File::Temp();

use List::Util qw{uniq};

use Provisioner::Utils();

=head1 Provisioner::Recipe::git

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        git:
            # One block per account on the guest, keyed by the account.  A
            # guest can hold a bot that pushes as itself and an administrator
            # who forwards their own key, and they want different things.
            accounts:
                koan:
                    # The forges it talks to, whose host keys it trusts.
                    hosts:
                        - github.com

                    # A key of its own, for pushing and for signing.
                    ssh_identity: 1

                    # Who the commits are from.  Required with ssh_identity,
                    # because a signature is attributed to an address.
                    user_name:  "yourname-bot"
                    user_email: "bot@example.com"

                doge:
                    # An operator who forwards a key wants the host keys and
                    # nothing else.
                    hosts:
                        - gitea.example.com

=head2 DESCRIPTION

What git needs to talk to a forge as somebody, which is a different question
from what the GitHub CLI needs.  L<Provisioner::Recipe::github> installs C<gh>
and logs it in with a token; this is the ssh key, the host keys and the
signature.  A bot wants both.  A machine whose operator logs in and forwards
their own key wants this one with no C<ssh_identity>, for the host keys alone.

The per-domain fragment does three things for each account, each only when
that account asked for it:

=over 4

=item * C<hosts> have their host keys scanned into the account's
F<known_hosts>.  Without them the first push waits on a prompt that nothing
answers, which reads as a hang rather than a refusal.  This happens whether or
not the account has a key, because a forwarded key meets the same prompt.

A scan that comes back with nothing says so on standard error and the build
carries on: a forge that is unreachable for a minute, or one that serves https
and no ssh, is not a reason to fail a provision.  The guest test reports it,
and a host that has no ssh to offer belongs out of C<hosts> -- which is a thing
to write under C<git> for the domain, since what an operator writes for a
recipe wins over what a dependent asked for it.

=item * C<ssh_identity> gives the account a key of its own and points ssh at it
for each of those hosts.

=item * C<user_name> and C<user_email> are the author of its commits, and with
a key the same key signs them.  C<allowed_signers> is written beside it, so
C<git log --show-signature> verifies them on the guest.

=back

=head2 ONE BLOCK PER ACCOUNT

C<accounts> is keyed by the account rather than naming one, because a domain
configures each recipe once and a guest holds more than one account.  The bot
and the administrator of the same guest want different things, and two recipes
asking for this one -- L<Provisioner::Recipe::github> for a login account and
L<Provisioner::Recipe::admincode> for the administrator -- would otherwise
disagree about which account it meant, which the depsolver refuses.

Two dependents that name the same account merge into one block: the hosts
concatenate, and C<enrich> takes the duplicates back out.

=head2 THE SSH KEY

The first build mints an Ed25519 key for each account that asked for one, keeps
it in the secret store as C<secret:git/E<lt>domainE<gt>-E<lt>accountE<gt>-ssh/password>,
and prints the public half.  B<The
forge does not know that key until somebody registers it> on the account, as an
authentication key and, where the forge has the idea, a signing key.

C<remote_files> does not name F<.ssh>, so the key is on the guest and in the
store and nowhere else.  A later provision takes it from the store, so
rebuilding the guest keeps the key the forge was told about.

To hand it a key that a forge already knows, put that key in the store before
the first build:

    bin/add_secret --group git --title <domain>-<account>-ssh --stdin < id_ed25519

That is also the move for a guest whose key something else minted.  The C<koan>
recipe held one at C<secret:koan/E<lt>domainE<gt>-github-ssh> until this recipe
took the work over, and a koan guest whose key is still under that group mints
a new one on the next provision unless it is copied across first.

=cut

sub args {
    return (
        type       => 'object',
        properties => {

            # The defaults are on the members of an account rather than on
            # accounts, so that a block naming one of them keeps the rest.
            accounts => {
                type                 => 'object',
                default              => {},
                description          => 'What each account on the guest gets, keyed by the account.',
                additionalProperties => {
                    type       => 'object',
                    properties => {
                        hosts => {
                            type        => 'array',
                            items       => { type => 'string' },
                            default     => [],
                            description => 'The forges whose host keys this account should trust, as hostnames.  A push to a host that is not here waits on a prompt nothing answers.',
                        },

                        ssh_identity => { type => 'boolean', default => 0, description => 'Give the account an ssh key of its own.  The key is minted into the secret store on the first build, and the public half has to be registered on the forge by hand.  Leave it off where the operator forwards a key.' },

                        user_name  => { type => 'string', description => 'The author name for commits from this account.' },
                        user_email => { type => 'string', description => 'The author address for commits from this account.  Required with ssh_identity, because that address is what a signature is attributed to.' },
                    },
                },
            },
        },
    );
}

=head3 %opts = $recipe->enrich(%opts)

Takes the duplicate hosts out of each account, which two dependents asking for
the same forge leave behind.

Dies when an account asks for C<ssh_identity> with no C<user_email>, and when
it asks for one with no C<hosts>: a key for a forge nobody named is a key with
nothing to push to.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    foreach my $account ( sort keys %{ $opts{accounts} } ) {
        my $said = $opts{accounts}{$account};

        $said->{hosts} = [ uniq sort @{ $said->{hosts} // [] } ];

        next unless $said->{ssh_identity};

        die "git: the $account account asks for ssh_identity with no user_email.  That address is what the signature is attributed to and what allowed_signers matches on.\n"
          unless $said->{user_email};

        die "git: the $account account asks for ssh_identity with no hosts, so the key has no forge to be a key for.\n"
          unless @{ $said->{hosts} };
    }

    return %opts;
}

=head3 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The ssh key of the account when C<ssh_identity> is on, and nothing when it is
off.  See L</THE SSH KEY>.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain, %opts ) = @_;

    my %placed;
    foreach my $account ( sort keys %{ $opts{accounts} // {} } ) {
        next unless $opts{accounts}{$account}{ssh_identity};

        $placed{"$install_dir/$domain/.ssh/id_git-$account"} = {
            ref => "secret:git/$domain-$account-ssh/password",

            # Ed25519 because the key fits in a password field, and no
            # passphrase because nothing is there to type one.
            generate => sub {
                my $dir  = File::Temp::tempdir( CLEANUP => 1 );
                my $path = "$dir/id_git";
                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => 256, "git-$account" );

                # Remove the trailing newline.  bin/provision adds one, and
                # ssh-keygen refuses a key that ends with a blank line.
                my $key = File::Slurper::read_binary($path);
                $key =~ s/\n\z//;
                return $key;
            },

            # Owned by root until the fragment gives it to the account, because
            # the file is placed before the makefile makes that account.
            mode => '0600',
        };
    }

    return %placed;
}

sub tests {
    return qw{git.tt};
}

1;
