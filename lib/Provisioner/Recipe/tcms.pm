package Provisioner::Recipe::tcms;

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
        # The libtool/seccomp/autotools stuff is all for inotify, which will move to tPSGI eventually
        return qw{sqlite3 libsqlite3-dev libmagic-dev git libxml2-dev libexpat1-dev libssl-dev zlib1g-dev g++};
    }
    die "Unsupported packager";
}

sub required_recipes {
    my ($self, %opts) = @_;
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
                        nocache_prefix =>  "/secure",
                        auth_statics   => "assets/private",
                        auth_uri       => "/authenticated",
                    },
                },
            );
        },
        tpsgi => sub {
            routers => [qq{tCMS/lib/TCMS.pm}],
            basedir => 'tCMS',
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


sub tests {
    return qw{tcms.tt};
}

1;
