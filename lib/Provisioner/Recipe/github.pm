package Provisioner::Recipe::github;

#ABSTRACT: Give an account on the guest the GitHub CLI, logged in.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::github

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        github:
            # The account on the guest this is for.  The service user by
            # default, which is what a bot wants; name the administrator for a
            # machine somebody logs in to.
            account: someadmin

            # The GitHub account, and a personal access token for it.  Both or
            # neither: one without the other cannot log anything in.
            github_user:  "yourname"
            github_token: "secret:github/yourname/password"

            # ssh, where the account has a key to push with.  The key itself is
            # Provisioner::Recipe::git.
            git_protocol: ssh

=head2 DESCRIPTION

The GitHub CLI, and the login state that makes it work without anybody typing
anything.

It is not the ssh key.  C<gh> authenticates with a token and needs no key at
all; a key is for pushing and for signing, which are git talking to a forge
rather than this.  L<Provisioner::Recipe::git> does that, and this recipe
requires it for the host keys of C<github.com>.  A bot asks for both, and gets
a key from the one that owns keys.

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

=back

Neither is required.  A domain that names this recipe and nothing else gets the
CLI and no login, which is what a machine whose operator logs in by hand wants.

=head2 WHAT RUNS WHEN

The CLI is installed by the global fragment, which the makefile runs before
every per-domain target.  So a recipe that requires this one can run C<gh> in
its own fragment whatever order the depsolver put them in.

The login is per domain, and a dependency's target runs B<after> the recipe
that required it.  A recipe that needs the login state rather than the binary
-- to clone as the account, say -- therefore does that work in a
C<queue_postrun_task>, which runs once every target has.
L<Provisioner::Recipe::koan> clones its projects that way.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            account      => { type => 'string', description => 'The account on the guest that gets the login.  Defaults to the service user of the domain.' },
            github_user  => { type => 'string', description => 'The GitHub account to log in as.' },
            github_token => { type => 'string', description => 'A personal access token for that account.  It is written into the login state of the account on the guest, so it is as secret as the guest is.' },

            git_protocol => { type => 'string', enum => [qw{https ssh}], default => 'https', description => 'What gh clones with.  ssh where the account has a key, which Provisioner::Recipe::git gives it; https otherwise, which authenticates with the token.' },
        },
    );
}

=head3 %required = $recipe->required_recipes(%opts)

C<git>, for the host keys of C<github.com>.  A push to a host whose keys the
account does not have waits on a prompt that nothing answers, and that is as
true of a key an operator forwards as of one a recipe placed.

It asks for no key here.  Whether this account has one of its own is a question
for whatever wanted a GitHub login in the first place, and it configures C<git>
for itself.

=cut

sub required_recipes {
    return (
        git => sub {
            my (%given) = @_;

            # Down to admin_user in the end, because this runs before
            # validation and so before user falls back to it there: a scaffold
            # has no service user yet, and admin_user an installation always
            # has.
            my $account = $given{account} // $given{user} // $given{admin_user};

            return ( accounts => { $account => { hosts => ['github.com'] } } );
        },
    );
}

=head3 %opts = $recipe->enrich(%opts)

Names the account when the configuration does not, which is the service user of
the domain.

Dies when only one of C<github_user> and C<github_token> is given.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{account} //= $opts{user};

    die "github: github_user and github_token go together.  One without the other logs nothing in, and gh then falls back to whatever is in the environment.\n"
      if !!$opts{github_user} != !!$opts{github_token};

    return %opts;
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
