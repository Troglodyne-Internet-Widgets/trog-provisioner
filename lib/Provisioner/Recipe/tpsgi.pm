package Provisioner::Recipe::tpsgi;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

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

Sets up TPSGI inside of the install_dir, so it can run your application schlepped over by the data recipe.

Optionally specify extra ENV vars to inject into the systemd service.

Requires the nginxproxy recipe, and with no overrides, will set up the vhost on 80/443.

TODO: allow specification of specific SHA to check out.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{git autotools-dev autoconf libseccomp-dev libtool libtool-bin};
    }
    die "Unsupported packager";
}

sub required_recipes {
    return (
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


# router is an absolute path
sub validate {
    my ( $self, %params ) = @_;

    my $router = $params{routers};
    die "Router file(s) must be set in [tpsgi] section as 'routers', no point using tpsgi without one" unless $router;

    return %params;
}

sub template_files {
    return (
        'tpsgi.tt' => 'tpsgi.ini',
    );
}

1;
