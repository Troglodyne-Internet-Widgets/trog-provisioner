package Provisioner::Recipe::roundcube;

#ABSTRACT: Install and configure the Roundcube webmail client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use UUID ();

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::roundcube

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        roundcube:
            version: "1.6.9"
            ipv6: true

=head2 DESCRIPTION

Downloads the 'complete' Roundcube webmail tarball for the specified version from
GitHub releases and installs it into $install_dir/webmail.$domain, served over
php-fpm behind an nginx vhost at webmail.[domain] (port 80 redirects to 443).

Each domain gets its own php-fpm pool listening on a dedicated unix socket, so
multiple roundcube installs can coexist on the same host.

User data (contacts, identities, preferences) lives in a SQLite database in
$install_dir/webmail.$domain_data, which is initialized from Roundcube's
sqlite.initial.sql as it will not autocreate. That directory is registered in
remote_files, so it is preserved across provisions and picked up by the
'backup' recipe.

Expects IMAP on mail.[domain]:143 and submission on mail.[domain]:587, i.e. a
host running L<Provisioner::Recipe::mail>. TLS uses the certificate provided by
the 'letsencrypt' recipe, so ensure 'webmail' is in the aliases section of
ipmap.cfg for your domain.

Requires the nginx recipe.

=cut

sub deps {
    my ( $self, %opts ) = @_;
    return qw{
      dbconfig-common
      enchant-2
      libapr1t64
      libaprutil1-dbd-sqlite3
      libaprutil1-ldap
      libaprutil1t64
      libenchant-2-2
      php
      php-fpm
      php-auth-sasl
      php-common
      php-enchant
      php-gd
      php-intl
      php-mbstring
      php-sqlite3
      php-zip
      sqlite3
    };
}

sub required_recipes {
    return ( nginx => sub { () } );
}

# NOTE: FPM php.ini: /etc/php/8.3/fpm/php.ini

sub template_files {
    my ( $class, @modules ) = @_;
    return (
        'roundcube.config.inc.php.tt' => 'config.inc.php',
        'roundcube.fpm.ini.tt'        => 'fpm.ini',
        'roundcube.nginx.tt'          => 'webmail_nginx.conf',
    );
}

sub makefile_vars {
    return (
        PHP_VER => q{$(shell php --version | egrep -o "[0-9]+\.[0-9]" | head -n 1)},
    );
}

sub args {
    return (
        required   => [qw{version}],
        properties => {
            version => { type => 'string' },
            ipv6    => { type => 'boolean', default => 1 },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;
    $opts{'des_key'} = 'rcube-' . UUID::uuid();
    return %opts;
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # SQLite database with user data (contacts, identities, preferences)
        "$install_dir/webmail.${domain}_data/" => 'roundcube/',
    );
}

sub tests {
    return qw{roundcube.tt};
}

1;
