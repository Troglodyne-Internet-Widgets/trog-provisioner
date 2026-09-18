package Provisioner::Recipe::roundcube;

#ABSTRACT: Install and configure the Roundcube webmail client.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

Downloads the 'complete' Roundcube webmail tarball of the given version from
GitHub releases, and installs it into $install_dir/webmail.$domain.  php-fpm
serves it behind an nginx vhost at webmail.[domain], and port 80 redirects to
443.

Each domain gets its own php-fpm pool, which listens on its own unix socket.  So
several roundcube installs can run on one host.

User data (contacts, identities, preferences) lives in a SQLite database in
$install_dir/webmail.$domain_data.  Roundcube does not create its own schema, so
the fragment loads it from sqlite.initial.sql.  C<remote_files> names that
directory, so it comes down off a guest that is rebuilt, and the 'backup' recipe
picks it up.

C<restores> puts it back where the DSN in config.inc.php points.  The C<data>
target does this before the fragment runs, and the fragment loads the schema
only when no database is there.  Nobody can type a contact list back in, so the
only other choice is to lose it.

Expects IMAP on mail.[domain]:143 and submission on mail.[domain]:587, that is,
a host that runs L<Provisioner::Recipe::mail>.  TLS uses the certificate from
the 'letsencrypt' recipe, so 'webmail' must be in the aliases section of
ipmap.cfg for your domain.

Requires the nginx recipe.

=cut

sub required_recipes {
    return ( nginx => sub { () } );
}

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

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # user falls back to admin_user as validate does, because required_recipes
    # runs before validation.
    my $user = $opts{user} // $opts{admin_user} // 'root';

    return ( "$install_dir/webmail.${domain}_data" => { from => "$install_dir/$domain/roundcube", owner => "$user:www-data" } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The sqlite database of user data.  See DESCRIPTION.
        "$install_dir/webmail.${domain}_data/" => 'roundcube/',
    );
}

sub tests {
    return qw{roundcube.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves roundcube's release tarballs: see C<github_release_hosts>
in L<Provisioner::Recipe>.

=cut

sub fetch_hosts {
    my ($class) = @_;
    return $class->github_release_hosts;
}

=head2 @classes = $recipe->cache_classes()

The classes for GitHub.  C<Provisioner::Recipe> holds them, so that the three
recipes that download a release do not each carry a copy.

=cut

sub cache_classes {
    my ($class) = @_;
    return $class->github_release_classes;
}

1;
