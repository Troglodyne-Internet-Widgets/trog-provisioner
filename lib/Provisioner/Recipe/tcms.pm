package Provisioner::Recipe::tcms;

#ABSTRACT: Install and configure tCMS in the install dir.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use feature 'state';

use HTTP::Tiny();
use Path::Tiny();

use Dist::Conformance::Check::SystemPackages();
use Dist::Conformance::Snapshot();
use Dist::Conformance::Snapshot::Tree();

use Provisioner::Utils();

# One copy for args, deps and fetch_hosts.
our $DEFAULT_REPO = 'https://github.com/Troglodyne-Internet-Widgets/tCMS.git';

=head1 Provisioner::Recipe::tcms

=head2 SYNOPSIS

    somedomain:
        tcms:
            # Optional.  Where to clone tCMS from, and which branch.
            repo_url:    "https://github.com/Troglodyne-Internet-Widgets/tCMS.git"
            repo_branch: "master"

=head2 DESCRIPTION

Installs tCMS in the install_dir.

The depsolver places C<tpsgi> after this recipe, so the checkout is on disk
before anything serves from it.

The checkout lives in C<tCMS/> in the directory of the domain.  It gets there in
one of two ways, and you do neither of them.  C<remote_files> brings the
checkout of the guest that this build replaces.  If there is none, the fragment
clones C<repo_branch> of C<repo_url>.  That happens for a domain that never existed, or for one whose
data directory somebody emptied.

This recipe leaves a checkout that is already there exactly as it is, in any
state.  It is the site that somebody runs, so this recipe does not reset,
update or reconcile it.  C<config/> is partly tracked, so a write into the
working tree replaces a live configuration with what master says today.

After the checkout is in place, the fragment runs the C<install> target of F<Installer.mk> in the
checkout, as the service user.  That target makes the directories that tCMS
needs and git does not track: C<data/> for its databases, C<totp/>, C<logs/>,
the C<www/> directories, and C<~/.tcms>.  Without C<data/>, tCMS cannot open
its database, and every request answers 500.  The target makes only what is
missing, so it does not change a checkout that came down from the last guest.

The guest test asks tCMS for its front page.  tCMS offers the page that
registers the first user only until it answers its first request, which
touches F<config/setup>.  So when that flag was not there before the test, the
test runs the C<reset> target of F<Installer.mk> and restarts tCMS.  A fresh
guest is then offered the setup page again.  A checkout that came down from
the last guest already has the flag, and the test leaves it alone.

TODO: let the configuration name a commit to check out (#223).

tCMS requires C<Sys::Virt>, so this recipe installs it before the other modules
that the checkout needs.  It pins the version that pkg-config reports for the
libvirt of the guest.  Without the pin, cpm takes the newest, and its build
wants a libvirt far newer than the distribution ships.
L<Provisioner::Recipe::trogrunner> pins it for the same reason.

=head2 THE SYSTEM PACKAGES

tCMS declares the system packages that it needs under C<x_system_packages> in
the F<metamerge.yml> of its repository.  See
L<Dist::Conformance::Check::SystemPackages>.  So the recipe names no package
itself: C<deps> of the subclass for a distribution asks C<declared_packages>
for those of its packager, and the guest installs them at first boot, before
the C<perl> recipe builds the modules of the checkout against them.

They are read when the configuration is generated, from C<repo_branch> of
C<repo_url>, and not from the checkout on the guest.  A guest that keeps the
checkout of the guest before it, as C<remote_files> says, gets the packages
that the branch declares now, and not those of the commit that it serves.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            repo_url    => { type => 'string', default => $DEFAULT_REPO, pattern => q{^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, description => 'The GitHub repository to clone tCMS from, which declares its system packages.' },
            repo_branch => { type => 'string', default => 'master',      pattern => q{^[A-Za-z0-9_.][A-Za-z0-9_./-]*$},                        description => 'The branch of repo_url that a new guest clones, and whose metamerge.yml names the system packages.' },
        },
    );
}

=head2 @packages = $recipe->declared_packages($packager, %opts)

The packages of C<$packager>, such as C<deb>, that F<metamerge.yml> on
C<repo_branch> of C<repo_url> in C<%opts> declares, or on the defaults of each.
It reads the file once for each repository and branch in each process, with
C<fetch>.

It dies rather than return no packages, because tCMS does not run without
them, and a guest without them fails long after the generation: when the file
cannot be fetched, with the answer of GitHub; when the repository has no
F<metamerge.yml>; when the declaration is not valid, with what
L<Dist::Conformance::Check::SystemPackages> said about it; and when it declares
no package of C<$packager>.

=cut

sub declared_packages ( $self, $packager, %opts ) {    ## no critic (ProhibitMisplacedMethods) -- the subclass of every distribution answers deps with it, and Ubuntu is the only one yet
    my $repo = $opts{repo_url} // $DEFAULT_REPO;
    my ( $owner, $name ) = $repo =~ m{\Ahttps://github[.]com/([^/]+)/([^/]+?)(?:[.]git)?/?\z}
      or die "tcms: $repo is not a repository on GitHub, so the recipe cannot read the system packages that it declares.\n";
    my $url = "https://raw.githubusercontent.com/$owner/$name/" . ( $opts{repo_branch} // 'master' ) . "/$Dist::Conformance::Check::SystemPackages::FILE";

    state %declared;
    my $declaration = $declared{$url} //= do {
        my $res = $self->fetch($url);
        die "tcms: $url is not there, so tCMS declares no system packages, and the guest would install none of what it needs.\n" if $res->{status} == 404;
        die "tcms: could not read the system packages of tCMS from $url: $res->{status} $res->{reason}" . ( $res->{status} == 599 ? ": $res->{content}" : "\n" )
          unless $res->{success};

        my $content  = $res->{content};
        my $snapshot = Dist::Conformance::Snapshot::Tree->new(
            paths => { $Dist::Conformance::Check::SystemPackages::FILE => Dist::Conformance::Snapshot::blob_sha($content) },
            fetch => sub ($) { return $content },
        );
        eval { Dist::Conformance::Check::SystemPackages->declared($snapshot) } // die "tcms: the system packages of tCMS at $url: $@";
    };

    my @packages = @{ $declaration->{$packager} // [] };
    die "tcms: $url declares no $packager packages, so the guest would install none of what tCMS needs.\n" unless @packages;
    return @packages;
}

=head2 $res = $recipe->fetch($url)

The L<HTTP::Tiny> response to a C<GET> of C<$url>.  The one place this recipe
reaches the network, so a test replaces it.

=cut

sub fetch ( $, $url ) {
    return HTTP::Tiny->new( timeout => 30 )->get($url);
}

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
                app_dir => 'tCMS',

                # Beside tpsgi.log, so that logshipper forwards the lines that
                # the tpsgi jail reads.
                loggers => ['Trog::Log::Syslog'],
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

=head2 @hosts = $recipe->fetch_hosts(%opts)

The host of C<repo_url>, which serves the tCMS checkout this recipe clones.

=cut

sub fetch_hosts ( $, %opts ) {
    return Provisioner::Utils::host_of( $opts{repo_url} // $DEFAULT_REPO );
}

1;
