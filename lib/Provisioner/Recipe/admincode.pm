package Provisioner::Recipe::admincode;

#ABSTRACT: Clone the admin user's git repositories onto the host.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::admincode

=head2 SYNOPSIS

    admincode:
        basedir: 'Code'
		repos_from:
			- api_url: https://wherever/api/
			  token: my_token
			  entities:
			      - my_github_user
            	  - my_github_org
				  ...

=head2 DESCRIPTION

Sets a domain's admin account up for working in: the packages a person needs at
a shell, and a checkout of every repository the accounts in C<repos_from> can
see, cloned into C<basedir> under the admin's home.

=head2 Cloning while the fetch cache is in front of it

C<repos_for> asks each C<api_url> what repositories an account has and clones
each one, trying C<clone_url> first and falling back to C<ssh_url>.  Two things
about that are worth knowing before it surprises somebody.

It runs B<during> the provision, from this recipe's own target, which is inside
the window where C<scripts/fetch_via_cache> has pointed every host in
C<fetch_hosts> at the cache.  An https clone is served through the cache and
works -- git's ref advertisement and its upload-pack POST both pass through
uncached, which C<templates/tests/fetchcache.tt> checks.

The ssh fallback cannot be.  F</etc/hosts> redirects every port for a host, and
the cache listens on 80 and 443, so an C<ssh_url> for a host the cache answers
for has nothing to connect to until the entries come back out at the end of the
build.  In practice this is the fallback doing its job -- gogs hands out ssh
addresses and nothing else, and a gogs host is not one any recipe names -- but
an https clone that fails transiently against a cached host will not be rescued
by the fallback the way it would be on a guest with no cache.


Clones all the repos owned by the specified entities known to the git server.
Also symlink to the admin user's $HOME as $basedir.

Uses L<Pithub> as the backend so should work with gogs or any other server w/ compatible API.

Does all of the clones read-only as the admin user, and then swaps out the origin for an r/w SSH origin.

Idea here is to set a developer or agent up in one step by cloning the many repos they need.
Setup your global git configuration via the skel mechanism in 'adminconfig'.

In the event the repo has a Makefile.PL we will attempt to install its' CPAN deps if the perl target is enabled.
In so doing we can utilize this recipe as part of smoking your own personal PAN.

If your repos have binary deps, add them to the list of deps you can install in the adminconfig recipe.

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

Each C<api_url> this domain is configured to ask, since C<repos_from> is where
the repositories come from.

Not the hosts it then clones from: those come back from that API as
C<clone_url>, so nothing here can know them before it has asked.  On a guest
where they turn out to be a host the cache answers for, the clone is served
through it, which is the arrangement working rather than a problem -- see the
caveat in the DESCRIPTION about the SSH fallback.

=cut

sub fetch_hosts {
    my ( $self, %opts ) = @_;

    return grep { $_ } map { $self->host_of( $_->{api_url} ) } @{ $opts{repos_from} // [] };
}

1;
