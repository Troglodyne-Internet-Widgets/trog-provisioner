package Provisioner::Recipe::Ubuntu::github;

#ABSTRACT: What github needs installed on Ubuntu.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe::github};

=head1 NAME

Provisioner::Recipe::Ubuntu::github - Ubuntu's C<deps> and archive for L<Provisioner::Recipe::github>.

=head2 @pkgs = $recipe->deps()

C<gh> comes from the archive of GitHub, which C<apt_sources> below names.  Noble
ships gh 2.45.0, which is older than the removal of the Projects-classic
GraphQL field.  So C<gh pr edit> fails there with a deprecation notice about
C<projectCards>, and edits nothing.

=cut

sub deps {
    return qw{gh curl ca-certificates};
}

=head2 @sources = $recipe->apt_sources()

The archive of the GitHub CLI.

=cut

sub apt_sources {
    return {
        name       => 'github-cli',
        uri        => 'https://cli.github.com/packages',
        suites     => ['stable'],
        components => ['main'],
        key        => 'https://cli.github.com/packages/githubcli-archive-keyring.gpg',
    };
}

1;
