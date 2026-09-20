package Provisioner::Recipe::github;

#ABSTRACT: Give an account on the guest the GitHub CLI, a login for it, and an ssh identity.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Slurper();
use File::Temp();

use Provisioner::Utils();

=head1 Provisioner::Recipe::github

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        github:
            # The account on the guest this is for.  The service user by
            # default, which is what a bot wants; name the administrator for a
            # machine somebody logs in to.
            account: doge

            # The GitHub account, and a personal access token for it.  Both or
            # neither: one without the other cannot log anything in.
            github_user:  "yourname"
            github_token: "secret:github/yourname/password"

            # An ssh key for pushing and for signing commits.  The key itself
            # is minted into the secret store on the first build.
            ssh_identity: 1
            git_email:    "you@example.com"

=head2 DESCRIPTION

Everything a guest needs to be somebody on GitHub, in one recipe, so that a bot
and a machine an operator works on get it the same way.

The CLI comes from GitHub's own archive at C<cli.github.com>, and that half is
the global fragment: one guest has one C<gh>, however many domains it holds.
Ubuntu's C<gh> is not used.  Noble ships 2.45.0, which predates the removal of
the Projects-classic GraphQL field, so C<gh pr edit> there fails with a
deprecation notice about C<projectCards> and edits nothing.

The per-domain fragment is about one account, C<account>:

=over 4

=item * C<github_user> and C<github_token> write F<.config/gh/hosts.yml> in
that account's home, which is the state C<gh auth login> would write.  So
C<gh repo clone> and C<gh api> work with nothing interactive, and
C<gh auth setup-git> makes git send the same token over HTTPS.

=item * C<ssh_identity> gives the account a key of its own, trusts the host
keys of C<github.com>, and points git at the key for that host.  The same key
signs commits and tags, and C<allowed_signers> lets
C<git log --show-signature> verify them on the guest.

=back

Neither is required.  A domain that names this recipe and nothing else gets the
CLI and no login, which is what a machine whose operator logs in by hand wants.

=head2 THE SSH KEY

The first build mints an Ed25519 key, keeps it in the secret store as
C<secret:github/E<lt>domainE<gt>-github-ssh/password>, and prints the public
half.  B<GitHub does not know that key until somebody registers it> on the
account, as an Authentication key and a Signing key.  Until then the account
can read public repositories over HTTPS with its token and nothing else.

C<remote_files> does not name F<.ssh>, so the key is on the guest and in the
store and nowhere else.  A later provision takes it from the store, so
rebuilding the guest keeps the key that GitHub was told about.

To keep a key that GitHub already knows, put it in the store before the first
build:

    bin/add_secret --group github --title <domain>-github-ssh --stdin < id_ed25519

That is also the move for a guest whose key this recipe did not mint.  The
C<koan> recipe held one at C<secret:koan/E<lt>domainE<gt>-github-ssh> until
this recipe took the work over, and a koan guest whose key is still under that
group mints a new one on the next provision unless it is copied across first.

=head2 WHAT RUNS WHEN

The CLI is installed by the global fragment, which the makefile runs before
every per-domain target.  So a recipe that requires this one can run C<gh> in
its own fragment whatever order the depsolver put them in.

The rest is per domain, and a dependency's target runs B<after> the recipe that
required it.  A recipe that needs the login state or the ssh key rather than
the binary -- to clone with the bot's identity, say -- therefore does that work
in a C<queue_postrun_task>, which runs once every target has.
L<Provisioner::Recipe::koan> clones its projects that way.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            account      => { type => 'string',  description => 'The account on the guest that gets the login and the key.  Defaults to the service user of the domain.' },
            github_user  => { type => 'string',  description => 'The GitHub account to log in as.' },
            github_token => { type => 'string',  description => 'A personal access token for that account.  It is written into the login state of the account on the guest, so it is as secret as the guest is.' },
            ssh_identity => { type => 'boolean', default     => 0, description => 'Give the account an ssh key for pushing and for signing.  The key is minted into the secret store on the first build; the public half has to be registered on the GitHub account by hand.' },

            git_name  => { type => 'string', description => 'The author name for commits from this account.  Defaults to github_user.' },
            git_email => { type => 'string', description => 'The author address for commits from this account.  Required with ssh_identity, because a signed commit with nobody to attribute it to is not what anybody meant.' },
        },
    );
}

=head3 %opts = $recipe->enrich(%opts)

Names the account when the configuration does not, which is the service user of
the domain, and the author name, which is the GitHub account.

Dies when only one of C<github_user> and C<github_token> is given, and when
C<ssh_identity> is on with no C<git_email>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{account}  //= $opts{user};
    $opts{git_name} //= $opts{github_user};

    die "github: github_user and github_token go together.  One without the other logs nothing in, and gh then falls back to whatever is in the environment.\n"
      if !!$opts{github_user} != !!$opts{github_token};

    die "github: ssh_identity needs a git_email, because that address is what the signature is attributed to and what allowed_signers matches on.\n"
      if $opts{ssh_identity} && !$opts{git_email};

    return %opts;
}

=head3 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

The ssh key of the account when C<ssh_identity> is on, and nothing when it is
off.  See L</THE SSH KEY> for what the first build does with it and how to hand
it a key that GitHub already knows.

=cut

sub guest_secrets {
    my ( $self, $install_dir, $domain, %opts ) = @_;

    return () unless $opts{ssh_identity};

    return (
        "$install_dir/$domain/.ssh/id_github" => {
            ref => "secret:github/$domain-github-ssh/password",

            # Ed25519 because the key fits in a password field, and no
            # passphrase because nothing is there to type one.
            generate => sub {
                my $dir  = File::Temp::tempdir( CLEANUP => 1 );
                my $path = "$dir/id_github";
                Provisioner::Utils::write_ssh_keypair( $path, Ed25519 => 256, 'github' );

                # Remove the trailing newline.  bin/provision adds one, and
                # ssh-keygen refuses a key that ends with a blank line.
                my $key = File::Slurper::read_binary($path);
                $key =~ s/\n\z//;
                return $key;
            },

            # Owned by root until the fragment gives it to the account, because
            # the file is placed before the makefile makes that account.
            mode => '0600',
        },
    );
}

=head3 @files = $recipe->template_files()

The login state of the account, which the fragment installs as
F<.config/gh/hosts.yml>.

=cut

sub template_files {
    return ( 'github.hosts.yml.tt' => 'github.hosts.yml' );
}

sub tests {
    return qw{github.tt};
}

=head3 @hosts = $recipe->fetch_hosts(%opts)

C<cli.github.com>, for the archive the CLI comes from.

C<github.com> is not in the list.  What a guest fetches from there is a clone
or an API call, each of which carries the account's credential, and a cache
must not keep either.

=cut

sub fetch_hosts {
    return ('cli.github.com');
}

=head3 @classes = $recipe->cache_classes()

The classes for the apt repository of the CLI.  See C<apt_repo_classes>.

=cut

sub cache_classes {
    my ($self) = @_;

    return $self->apt_repo_classes('cli.github.com');
}

1;
