package Provisioner::Recipe::tpsgi;

#ABSTRACT: Set up TPSGI to run the deployed application.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Path::Tiny();

=head1 Provisioner::Recipe::tpsgi

=head2 SYNOPSIS

    somedomain:
        tpsgi:
            routers:
                - my/lib/Router.pm
	        basedir: "path/to/tcms/install"
        # Example: running on other port than default 80/443
        nginxproxy:
            vhosts:
                8080:
                    proxy_uri:  run/tpsgi.sock
                    static_dir: www/

=head2 DESCRIPTION

Sets up TPSGI in the directory of the domain under C<install_dir>.  TPSGI then
runs the application that the data recipe copies there.

It requires the C<perl> recipe, which installs Starman and the dependencies of
the checkout.  It also requires the C<nginxproxy> recipe.  With no overrides,
C<nginxproxy> sets up the vhost on ports 80 and 443.

The checkout is the head of the default branch of tPSGI.  You cannot choose a
commit.

=cut

sub required_recipes {
    return (
        # build_service starts the application with Starman.  The perl target
        # runs after this fragment makes the checkout, and before the postrun
        # starts the service.  See cpan_deps in Provisioner::Recipe::perl.
        perl => sub {
            my (%opts) = @_;
            return (
                cpan_deps => [
                    { install     => ['Starman'] },
                    { installdeps => Path::Tiny::path( @opts{qw{install_dir domain}} )->stringify },
                ],
            );
        },
        nginxproxy => sub {
            my (%opts) = @_;
            return (
                vhosts => {
                    80 => {
                        proxy_uri  => "run/tpsgi.sock",
                        static_dir => "www/static",
                    },
                    443 => {
                        proxy_uri  => "run/tpsgi.sock",
                        static_dir => "www/static",
                        ssl        => 1,
                    },
                },
            );
        },
    );
}

sub args {
    return (
        type       => 'object',
        required   => [qw{routers}],
        properties => {
            basedir => { type => 'string' },
            routers => { type => 'array', items => { type => 'string' }, default => [] },
        },
    );
}

sub template_files {
    return (
        'tpsgi.tt' => 'tpsgi.ini',
    );
}

sub tests {
    return qw{tpsgi.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

Returns C<github.com>, which serves the tPSGI checkout that this recipe clones.

=cut

sub fetch_hosts {
    return qw{github.com};
}

1;
