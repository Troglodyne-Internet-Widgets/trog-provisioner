package Provisioner::Recipe::claude;

#ABSTRACT: Install claude-code globally.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::claude

=head2 SYNOPSIS

    somedomain:
        claude:

=head2 DESCRIPTION

Install claude-code globally.

SLOP in the ice machine.

=head2 Whose name the guest acts under

An agent on a guest opens pull requests, replies to review threads and makes
commits, and every one of those is attributed to whoever's credentials it found.
Left to inherit an operator's, its work is indistinguishable from theirs -- which
is a problem of attribution rather than of access, and shows up as a review
thread answered by the person who opened it.

Give it C<github_user> and C<github_token> and it acts as that account instead.
Both are optional: a guest configured with neither keeps whatever credentials
were put there by hand, which is what every guest did before this existed.

Two different things decide attribution, and configuring one without the other
is the usual surprise:

=over 4

=item * B<The token> settles what the API does -- comments, reviews, pull
request edits.  That is C<github_token>, seeded into gh so the guest never needs
an interactive C<gh auth login>.

=item * B<The commit email> settles commit authorship, because GitHub maps a
commit to an account by it.  That is C<git_email>, and a bot's
C<< <id>+<login>@users.noreply.github.com >> is what makes the log say the bot.

=back

Neither touches B<who pushed>.  A guest pushing over ssh does so as whichever
key it holds, and a token changes nothing about that.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            github_user => {
                type        => 'string',
                description => 'The GitHub account this guest acts as.  Without it the guest uses whatever credentials an operator left on it.',
            },
            github_token => {
                type        => 'string',
                description => 'A personal access token for that account, written secret:GROUP/ENTRY/FIELD.  It seeds gh, so a review reply or a pull request edit from this guest comes from the bot rather than from whoever owns the workstation it was built from.',
            },
            git_email => {
                type        => 'email',
                description => "The address on commits this guest makes.  GitHub attributes a commit by its email and by nothing else, so the token alone will not move authorship -- a bot's <id>+<login>\@users.noreply.github.com will.",
            },
            git_name => {
                type        => 'string',
                description => 'The name on commits this guest makes.  Defaults to github_user.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

C<git_name> follows C<github_user>, which is what it should be in every case
where the operator has not said otherwise.

Derived here rather than declared in the schema because a schema default cannot
read another field.  A domain naming C<git_name> keeps what it named.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{git_name} //= $opts{github_user};

    return %opts;
}

sub template_files {
    return (
        'claude.settings.json.tt' => 'claude.settings.json',

        # Always rendered; empty when github_token is unset.  The makefile
        # fragment skips installing it in that case.
        'claude.gh-hosts.yml.tt' => 'claude.gh-hosts.yml',
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        "$install_dir/$domain/.claude.json" => '.claude.json',
    );
}

sub tests {
    return qw{claude.tt};
}

1;
