package Provisioner::Recipe::tcms;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::tcms

=head2 SYNOPSIS

    somedomain:
        tcms:
	    install_dir: "path/to/tcms/install"

=head2 DESCRIPTION

Runs the needed installation steps for a tCMS installation inside of the install_dir.
The install dir is expected to be an existing tCMS installation inside of the data dir (can simply be a fresh clone).

If you want the system to come up right away, it's a good idea to set the order of this higher than that of the tpsgi target.

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

# router is an absolute path
sub validate {
    my ( $self, %params ) = @_;

    my $path = $params{tcms_dir};
    die "tcms_dir must be set in [tcms] section as relative path" unless $path;

    return %params;
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # tCMS stores some persistent logs in the tpsgi log dir.
        "$install_dir/$domain/log"              => "log/",
        "$install_dir/$domain/tCMS/www/assets/" => 'tCMS/www/assets/',
        "$install_dir/$domain/tCMS/config/"     => 'tCMS/config/',
        "$install_dir/$domain/tCMS/data/"       => 'tCMS/data',
    );
}


1;
