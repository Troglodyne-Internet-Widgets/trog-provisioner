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

Runs the needed installation steps for a tCMS installation inside of the
install_dir.

If you want the system to come up right away, it's a good idea to set the order of this higher than that of the tpsgi target.

The checkout lives in C<tCMS/> under the domain's directory.  It gets there one
of two ways and neither of them is yours to do: C<remote_files> brings the one
off the guest being replaced, and the fragment clones master when there is none
-- a domain that has never existed, or one whose data directory somebody has
emptied.

A checkout that is already there is left exactly as it is, whatever state it is
in.  It is the site somebody has been running, and it is not this recipe's to
reset, update or reconcile: C<config/> is partly tracked, so anything that wrote
into the working tree would be overwriting a live configuration with whatever
master says today.

TODO: allow specification of specific SHA to check out.

=cut

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
        "$install_dir/$domain/log" => "log/",

        # The whole checkout, rather than the three directories inside it that
        # hold content.  Which commit the guest was actually serving is state as
        # much as the assets are -- a site pinned to a revision, or carrying a
        # patch that has not been pushed, came back as whatever master happened
        # to be that morning.  The .git is what says which, and it is small
        # beside the assets that were coming down anyway.
        "$install_dir/$domain/tCMS/" => "tCMS/",
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
    return ('secrets.key');
}

sub tests {
    return qw{tcms.tt};
}

1;
