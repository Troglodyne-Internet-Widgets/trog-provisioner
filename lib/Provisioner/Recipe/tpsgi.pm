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
            routers => { type => 'array', items => { type => 'string' } },
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

=head2 %jails = $recipe->jails(%opts)

A jail for the domain, which bans a host whose logins fail too often.  tCMS
writes each failure into the log of tPSGI, in the format of its C<Trog::Log>:

    2026-08-27T21:51:59Z [INFO]: RequestId INIT From ::ffff:192.0.2.104 |nobody| Failed login for user someadmin

and C<TOTP auth failed for user> when the password was right and the code was
not.  fail2ban reads the IPv4 address out of an IPv4-mapped one, so the ban
covers the client.  The request lines that tPSGI itself writes have a format
of their own, and none of them says that a login failed, because tCMS answers
a failed login with a 200.

It is named after the domain, because two domains on one guest each have
their own log.

=cut

sub jails {
    my ( $self, %opts ) = @_;

    return (
        "tpsgi-$opts{domain}" => {
            filter      => '',
            backend     => 'auto',
            port        => 'http,https',
            logpath     => "$opts{install_dir}/$opts{domain}/log/tpsgi.log",
            datepattern => '%%Y-%%m-%%dT%%H:%%M:%%SZ',
            failregex   => '^ \[INFO\]: RequestId \S+ From <HOST> \|\S+\| (?:Failed login|TOTP auth failed) for user',
            maxretry    => 5,
            findtime    => 600,
            bantime     => 3600,
        }
    );
}

=head2 @hosts = $recipe->fetch_hosts()

Returns C<github.com>, which serves the tPSGI checkout that this recipe clones.

=cut

sub fetch_hosts {
    return qw{github.com};
}

1;
