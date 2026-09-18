package Provisioner::Recipe::admincode;

#ABSTRACT: Clone the admin user's git repositories onto the host.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 Provisioner::Recipe::admincode

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        admincode:
            basedir: 'Code'
            repos_from:
                - api_url: https://wherever/api/
                  token: my_token
                  repos_for:
                      - my_github_user
                      - my_github_org
            extra_pkgs:
                - build-essential

=head2 DESCRIPTION

Sets up the admin account of a domain for work at a shell.  It installs C<gh>,
C<git> and the C<extra_pkgs>.  It clones every repository that each entity in
C<repos_for> owns on the git server at C<api_url>.

The clones go into C<basedir> under the directory of the domain.  If the admin
user is not the service user, a link named C<basedir> in the home of the admin
points to them.  If the link name exists already, the recipe leaves it alone.

L<Pithub> talks to the server, so gogs or any other server with a compatible
API also works.  F<scripts/repos_for> clones each repository as the admin user
over https.  Then it sets the origin to the ssh URL, so the admin can push.

The purpose is to set up a developer or an agent with all of their repositories
in one step.  Supply the global git configuration of the admin through the
C<skel> of L<Provisioner::Recipe::adminconfig>.

If the C<perl> recipe is enabled, the CPAN dependencies of each repository that
has a F<Makefile.PL> are installed, and its tests are run.  So this recipe can
smoke your own personal PAN.  If your repositories need system packages, list
them in C<extra_pkgs>.

=head2 Cloning while the fetch cache is in front of it

F<scripts/repos_for> asks each C<api_url> for the repositories of an entity.
It clones each one from C<clone_url> first, and from C<ssh_url> if that fails.

This happens B<during> the provision, from the target of this recipe.  At that
time, C<scripts/fetch_via_cache> points every host in C<fetch_hosts> at the
cache.  An https clone goes through the cache and works.  git sends its ref
advertisement and its upload-pack POST through without caching them.
C<templates/tests/fetchcache.tt> tests this.

The ssh fallback cannot go through the cache.  F</etc/hosts> sends every port
for a host to the cache, and the cache listens only on 80 and 443.  So an
C<ssh_url> for a host that the cache answers for has nothing to connect to.
The entries leave F</etc/hosts> at the end of the build.

Usually the fallback is for gogs, which gives only ssh addresses, and no recipe
names a gogs host.  But if an https clone fails for a short time against a
cached host, the fallback does not recover it.  On a guest with no cache, it
does.

=cut

sub args {
    return (
        type       => 'object',
        required   => [qw{repos_from basedir}],
        properties => {
            basedir    => { type => "string" },
            repos_from => {
                type  => "array",
                items => {
                    type       => "object",
                    required   => [qw{api_url token repos_for}],
                    properties => {
                        api_url   => { type => "string" },
                        token     => { type => "string" },
                        repos_for => {
                            type  => "array",
                            items => { type => "string" },
                        },
                    },
                },
            },
            extra_pkgs => {
                type  => "array",
                items => { type => "string" }
            },

        },
    );
}

sub tests {
    return qw{admincode.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

Returns C<cli.github.com>, for the signing key of C<gh>, and the host of each
C<api_url> in C<repos_from>.

The hosts that the clones come from are not in the list.  The API gives them
as C<clone_url>, so this method cannot know them in advance.  If one of them is
a host that the cache answers for, the clone goes through the cache.  That is
correct.  See L</Cloning while the fetch cache is in front of it> for the ssh
fallback.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;

    return ( 'cli.github.com', grep { $_ } map { Provisioner::Utils::host_of( $_->{api_url} ) } @{ $opts{repos_from} // [] } );
}

=head2 @classes = $recipe->cache_classes()

Returns the classes for the apt repository of C<gh>.  The repository API is
not in it, because each answer is for one account and one token, and the cache
must not keep it.

=cut

sub cache_classes {
    my ($self) = @_;

    return $self->apt_repo_classes('cli.github.com');
}

1;
