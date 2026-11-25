package Provisioner::Recipe::admincode;

#ABSTRACT: Clone the admin user's git repositories onto the host.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util();

use Provisioner::Packager();
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

Sets up the admin account of a domain for work at a shell.  It installs
C<git> and the C<extra_pkgs>, and requires L<Provisioner::Recipe::github> for
the GitHub CLI.  It clones the repositories of each entity in C<repos_for> on
the git server at C<api_url>.  Of an organization, it clones every repository
that the owner of C<token> can see.  Of a user, it clones the public
repositories, whoever owns C<token>.  An entity that the server does not call
an organization counts as a user.

The clones go into C<basedir> under the directory of the domain.  If the admin
user is not the service user, a link named C<basedir> in the home of the admin
points to them.  If the link name exists already, the recipe leaves it alone.

L<Pithub> talks to the server, so gogs or any other server with a compatible
API also works.  F<scripts/repos_for> clones each repository as the admin user
over https.  Then it sets the origin to the ssh URL, so the admin can push.
A repository with a F<git-hooks> or F<githooks> directory gets those hooks in
F<.git/hooks>, so its commit checks run from the first commit.  A hook already
there stays as it is.

The purpose is to set up a developer or an agent with all of their repositories
in one step.  Supply the global git configuration of the admin through the
C<skel> of L<Provisioner::Recipe::adminconfig>.

=head2 On a guest that runs claude

With L<Provisioner::Recipe::claude>, each clone becomes an entry of
C<permissions.additionalDirectories> in the settings of the domain, so the
agent can read and write it.  That entry does not load the skills in the
F<.claude/skills> of the clone.  Claude Code loads those only for a directory
that the session starts with C<--add-dir>, or that C</add-dir> adds during it.

So the recipe also gives the admin F<~/.bashrc.d/50-admincode-E<lt>domainE<gt>>,
through F<scripts/bashrc_d>.  It defines a C<claude> function that passes
C<--add-dir> for each clone in C<basedir> that has a F<.claude/skills>, and for
no other.  Claude Code asks the admin to trust each directory that C<--add-dir>
names, and only the skills need the flag.  The function lists the clones each
time it runs, so a later clone needs no provision.  If several domains on one
machine run this recipe, the function adds the clones of each.

If the C<perl> recipe is enabled, the CPAN dependencies of each repository are
installed into the perl that it built, and then the tests of the repository run
against that perl.  A repository with a F<dist.ini> gets what C<dzil> says it
needs, author dependencies included.  One with a F<Makefile.PL> or a
F<Build.PL> gets what cpanm reads from it.  A repository with none of these is
skipped.  So this recipe can smoke your own personal PAN.

A repository that the API calls a fork is cloned, and not smoked.  Its suite is
the business of the project that it came from.

A repository declares the system packages that it needs in F<metamerge.yml>,
as L<Dist::Conformance::Check::SystemPackages> describes.  The smoke installs
what each declaration names for the guest before the dependencies from CPAN,
with C<conformance packages> from L<Dist::Conformance>, which it installs into
the perl first.  A package that a repository needs and does not declare goes
in C<extra_pkgs>.

The install runs as root, and the tests run as the admin, who owns the clones.
Every file that the install leaves in a clone goes to the admin afterwards.  See
F<scripts/smoke_perl_modules.pl>.

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

=head1 METHODS

=head2 %required = $recipe->required_recipes(%opts)

C<github> for the CLI, which somebody working at a shell on the guest expects
and which used to be installed here, and C<git> for the host keys of the host
that serves ssh for each C<api_url> it clones from.  That is the host of the
C<api_url>, except for C<api.github.com>: GitHub serves ssh from
C<github.com>, and C<api.github.com> answers no ssh at all.

Neither is given a login or a key.  An administrator logs in as themselves and
forwards their own key; the host keys are the half of that which the guest has
to have either way, because the C<ssh_url> fallback in F<scripts/repos_for>
meets the same prompt as any other push and nothing is there to answer it.

Returns a list of pairs, from the name of each required recipe to a code
reference that takes the options of this recipe and returns the options of
that one.

    my %required = $recipe->required_recipes();
    my %git      = $required{git}->( admin_user => 'admin', repos_from => [ { api_url => 'https://forge.test.test/api/v1/' } ] );

=cut

sub required_recipes {
    return (
        github => sub { () },
        git    => sub {
            my (%given) = @_;

            return (
                accounts => {
                    $given{admin_user} => {
                        hosts => [
                            grep { $_ }
                            map {

                                # GitHub Enterprise and gogs serve the API and ssh from one host.
                                my $host = Provisioner::Utils::host_of( $_->{api_url} ) // q{};
                                $host eq 'api.github.com' ? 'github.com' : $host
                            } @{ $given{repos_from} // [] }
                        ],
                    },
                },
            );
        },
    );
}

=head2 %schema = $recipe->args()

The schema of the options: C<basedir>, a string, and C<repos_from>, a list of
objects that each have an C<api_url>, a secret C<token> and C<repos_for>, a
list of the users and organizations to clone.  Both are required.
C<extra_pkgs> is an optional list of packages.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

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
                        token     => { type => "string", 'x-secret' => 1 },
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

=head2 %opts = $recipe->enrich(%opts)

Adds C<install_command>, the words of the C<install_command> of the
L<Provisioner::Packager> that C<distro_packager> names, which the smoke runs
with the system packages that a repository declares.

Returns C<%opts>, with C<install_command> added as an array reference of
words.

    my %opts = $recipe->enrich( domain => 'test.test', basedir => 'Code' );

=cut

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{install_command} = [ Provisioner::Packager->named( $self->distro_packager )->install_command ];
    return %opts;
}

=head2 %files = $recipe->template_files(@recipes)

F<admincode.claude.bash>, on a guest that also runs claude.

=over 4

=item @recipes - Str - the names of the recipes that the guest runs

=back

Returns the pair C<admincode.claude.bash.tt> and C<admincode.claude.bash>
when C<@recipes> has C<claude>, and nothing otherwise.

    my %files = $recipe->template_files(qw{admincode claude});

=cut

sub template_files {
    my ( $self, @recipes ) = @_;
    return ( List::Util::any { $_ eq q{claude} } @recipes ) ? ( 'admincode.claude.bash.tt' => 'admincode.claude.bash' ) : ();
}

=head2 @tests = $recipe->tests()

Returns a list of the test templates that run on the guest: F<admincode.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{admincode.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

Returns the host of each C<api_url> in C<repos_from>.  The archive of the
GitHub CLI is L<Provisioner::Recipe::github>'s to name.

The hosts that the clones come from are not in the list.  The API gives them
as C<clone_url>, so this method cannot know them in advance.  If one of them is
a host that the cache answers for, the clone goes through the cache.  That is
correct.  See L</Cloning while the fetch cache is in front of it> for the ssh
fallback.

There are no C<cache_classes> either.  Each answer from the API is for one
account and one token, so the cache must not keep it.

    my @hosts = $recipe->fetch_hosts( repos_from => [ { api_url => 'https://forge.test.test/api/v1/' } ] );

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;

    return grep { $_ } map { Provisioner::Utils::host_of( $_->{api_url} ) } @{ $opts{repos_from} // [] };
}

1;
