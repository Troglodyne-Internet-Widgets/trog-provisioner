package Provisioner::Recipe::tcms;

#ABSTRACT: Install and configure tCMS in the install dir.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Path::Tiny();

=head1 Provisioner::Recipe::tcms

=head2 SYNOPSIS

    somedomain:
        tcms:

=head2 DESCRIPTION

Installs tCMS in the install_dir.

The depsolver places C<tpsgi> after this recipe, so the checkout is on disk
before anything serves from it.

The checkout lives in C<tCMS/> in the directory of the domain.  It gets there in
one of two ways, and you do neither of them.  C<remote_files> brings the
checkout of the guest that this build replaces.  If there is none, the fragment
clones master.  That happens for a domain that never existed, or for one whose
data directory somebody emptied.

This recipe leaves a checkout that is already there exactly as it is, in any
state.  It is the site that somebody runs, so this recipe does not reset,
update or reconcile it.  C<config/> is partly tracked, so a write into the
working tree replaces a live configuration with what master says today.

TODO: let the configuration name a SHA to check out.

tCMS requires C<Sys::Virt>, so this recipe installs it before the other modules
that the checkout needs.  It pins the version that pkg-config reports for the
libvirt of the guest.  Without the pin, cpanm takes the newest, and its build
wants a libvirt far newer than the distribution ships.
L<Provisioner::Recipe::trogrunner> pins it for the same reason.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    return (
        nginxproxy => sub {
            my (%nginxproxy_opts) = @_;
            return (
                vhosts => {
                    80 => {
                        nocache_prefix => "/secure",
                        auth_statics   => "assets/private",
                        auth_uri       => "/authenticated",
                    },
                    443 => {
                        nocache_prefix => "/secure",
                        auth_statics   => "assets/private",
                        auth_uri       => "/authenticated",
                    },
                },
            );
        },

        # The dependencies of the checkout, installed into the perl that the perl
        # recipe builds.  See cpan_deps in Provisioner::Recipe::perl, and
        # DESCRIPTION on why Sys::Virt goes first.
        perl => sub {
            my (%perl_opts) = @_;
            return (
                cpan_deps => [
                    { pin         => { module => 'Sys::Virt', pkgconfig => 'libvirt' } },
                    { installdeps => Path::Tiny::path( @perl_opts{qw{install_dir domain}}, 'tCMS' )->stringify },
                ],
            );
        },
        tpsgi => sub {
            return (
                routers => [qq{tCMS/lib/TCMS.pm}],
                basedir => 'tCMS',
            );
        },
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # tCMS keeps some persistent logs in the log directory of tpsgi.
        "$install_dir/$domain/log" => "log/",

        # The whole checkout, not only the directories in it that hold content.
        # The commit that the guest serves is state too, and .git records it.
        "$install_dir/$domain/tCMS/" => "tCMS/",
    );
}

=head2 @patterns = $recipe->remote_skip()

C<secrets.key>.  C<remote_files> brings F<tCMS/config/> down whole, and this
keeps one file in it behind.

tCMS seals the stored secrets of its users with F<config/secrets.key>.  The key
is not in backups and does not travel, so a stolen F<config/auth.db> is of no
use without it.  The key lives and dies with the machine that made it.

So a rebuilt guest comes up without it.  Every stored secret is then unreadable,
and each user stores theirs again.  tCMS handles that quietly, and it is the
cheaper half of the trade.

tCMS installs that tPSGI runs under systemd do not have this file.  There the
key is a systemd credential, and it is never a file on the guest.  This is for
installs that use C<bin/tcms-vault-key --file>.

=cut

sub remote_skip {
    return ('secrets.key');
}

sub tests {
    return qw{tcms.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

GitHub, which serves the tCMS checkout this recipe clones.

=cut

sub fetch_hosts {
    return qw{github.com};
}

1;
