package Provisioner::Recipe::tcms;

#ABSTRACT: Install and configure tCMS in the install dir.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::tcms

=head2 SYNOPSIS

    somedomain:
        tcms:

=head2 DESCRIPTION

Runs the needed installation steps for a tCMS installation inside of the install_dir.
The install dir is expected to be an existing tCMS installation inside of the data dir (can simply be a fresh clone).

If you want the system to come up right away, it's a good idea to set the order of this higher than that of the tpsgi target.

Your tCMS install MUST be in the tCMS/ directory in the DATA 'from' dir.

TODO: allow specification of specific SHA to check out.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {

        # libtool, seccomp and autotools are all for inotify, which will move to tPSGI eventually
        return qw{sqlite3 libsqlite3-dev libmagic-dev git libxml2-dev libexpat1-dev libssl-dev zlib1g-dev g++ inkscape};
    }
    die "Unsupported packager";
}

sub required_recipes {
    my ( $self, %opts ) = @_;
    return (
        nginxproxy => sub {
            my (%opts) = @_;
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
        tpsgi => sub {

            # Explicit, like nginxproxy above.  It was an implicit return of a
            # comma expression, which is the same list and which perltidy cannot
            # tell from a block it should be putting statements in.
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
        # tCMS stores some persistent logs in the tpsgi log dir.
        "$install_dir/$domain/log"              => "log/",
        "$install_dir/$domain/tCMS/www/assets/" => "tCMS/www/assets/",
        "$install_dir/$domain/tCMS/config/"     => "tCMS/config/",
        "$install_dir/$domain/tCMS/data/"       => "tCMS/data",
    );
}

# tCMS/config/ comes down whole, and one thing in it must not.
#
# config/secrets.key is what tCMS seals its users' stored secrets with, and it is
# deliberately not backed up and deliberately not carried anywhere: the point of
# it is that a stolen config/auth.db is ciphertext, which stops being true the
# moment the key travels in the same tarball as the database.  It lives and dies
# with the machine it was made on.
#
# So a rebuilt guest comes up without it, every stored secret reads as unreadable,
# and each user stores theirs again -- which tCMS is built to do quietly rather
# than to fall over on.  That is the cost, and it is the cheaper half of the trade.
#
# tCMS installs run by tPSGI under systemd do not have this file at all; the key
# is a systemd credential there and was never inside the guest's filesystem to
# salvage.  This is for the ones using bin/tcms-vault-key --file.
sub remote_skip {
    return (qr{/tCMS/config/secrets\.key$});
}

sub tests {
    return qw{tcms.tt};
}

1;
