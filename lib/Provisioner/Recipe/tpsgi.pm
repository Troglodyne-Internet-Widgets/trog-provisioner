package Provisioner::Recipe::tpsgi;

#ABSTRACT: Set up TPSGI to run the deployed application.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Module::Runtime();
use Path::Tiny();

use Provisioner::Recipe::servicesudo();

=head1 Provisioner::Recipe::tpsgi

=head2 SYNOPSIS

    somedomain:
        tpsgi:
            routers:
                - my/lib/Router.pm
            app_dir: "path/to/tcms/install"
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
C<nginxproxy> sets up the vhost on ports 80 and 443.  And it requires
C<servicesudo>, which lets the service user restart F<$domain.service>, and
ask for its status, with sudo, as
L<Provisioner::Recipe::servicesudo/unit_commands> says.

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
                    { install => ['Starman'] },
                    { dzil    => Path::Tiny::path( @opts{qw{install_dir domain}} )->stringify },
                ],
            );
        },
        servicesudo => sub {
            my (%opts) = @_;
            return ( commands => [ Provisioner::Recipe::servicesudo::unit_commands("$opts{domain}.service") ] );
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

=head2 %opts = $recipe->enrich(%opts)

Dies when an entry of C<loggers> is not the name of a Perl module, such as
C<1Foo::Bar>, because tPSGI loads each one by name.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @bad = grep { !Module::Runtime::is_module_name($_) } @{ $opts{loggers} // [] };
    die "loggers must be names of Perl modules, and these are not: @bad\n" if @bad;

    return %opts;
}

sub args {
    return (
        type       => 'object',
        required   => [qw{routers}],
        properties => {
            app_dir => { type => 'string', description => 'The directory of the application, relative to the directory of the domain.  tPSGI changes into it before each request.  Unset is the directory of the domain.' },
            routers => { type => 'array',  items       => { type => 'string' } },
            loggers => {
                type        => 'array',
                items       => { type => 'string' },
                description => 'Log::Dispatch output classes that tPSGI adds to its log, and that it hands to the application.  It loads each by name, so a class can live beside a router.  Each must be the name of a Perl module, which enrich checks.',
            },
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
