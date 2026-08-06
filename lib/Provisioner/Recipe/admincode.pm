package Provisioner::Recipe::admincode;

use strict;
use warnings;

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

Clones all the repos owned by the specified entities known to the git server.
Also symlink to the admin user's $HOME as $basedir.

Uses L<Pithub> as the backend so should work with gogs or any other server w/ compatible API.

Does all of the clones read-only as the admin user, and then swaps out the origin for an r/w SSH origin.

Idea here is to easily set up stuff for developers/agents by cloning the many repos they need.
Setup your global git configuration via the skel mechanism in 'adminconfig'.

In the event the repo has a Makefile.PL we will attempt to install its' CPAN deps if the perl target is enabled.
In so doing we can utilize this recipe as part of smoking your own personal PAN.

If your repos have binary deps, add them to the list of deps you can install in the adminconfig recipe.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{libpithub-perl git};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;
    my $repos = $opts{repos_from};
    die "Must set repos in [admincode] section of recipes.yaml" unless $repos && ref $repos eq 'ARRAY';
    my $basedir = $opts{basedir};
    die "Must set basedir in [admincode] section of recipes.yaml" unless $basedir;

    if ($opts{extra_pkgs} && ref $opts{extra_pkgs} ne 'ARRAY') {
        die "admincode.extra_pkgs must be array";
    }
    return %opts;
}

sub tests {
    return qw{admincode.tt};
}

1;
