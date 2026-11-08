package Provisioner::Recipe::tcms;

#ABSTRACT: Install and configure tCMS in the install dir.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use feature 'state';

use File::Temp();
use IPC::Run3();
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
            # Optional.  Jobs that the transcode worker runs at once.
            worker_jobs: 1
            # Optional.  The name of the logins, for a site behind a relay.
            secure_host: secure.somedomain

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

The fragment does set the owner of the checkout, which the service user and
its own group own.  C<www/> is the exception, and has the group C<www-data>.
The first time tPSGI serves a file out of C<www/>, it hard-links the file into
the F<www/static> of the domain, where nginx serves it from then on.  A hard
link has the group and the mode of the file, so nginx reads a linked file only
through its group.  Nothing else in the checkout is for nginx, and the group
of the service user keeps it out.

After the checkout is in place, the fragment runs the C<install> target of F<Installer.mk> in the
checkout, as the service user.  That target makes the directories that tCMS
needs and git does not track: C<data/> for its databases, C<totp/>, C<logs/>,
the C<www/> directories, and C<~/.tcms>.  Without C<data/>, tCMS cannot open
its database, and every request answers 500.  The target makes only what is
missing, so it does not change a checkout that came down from the last guest.

Then the fragment runs the C<prereq-frontend> target, as the service user.  It
downloads the scripts and styles that tCMS serves and git does not track, such
as the emoji list of the emoji picker, from C<raw.githubusercontent.com> and
C<cdn.jsdelivr.net>.  F<Installer.mk> fetches only the files that are missing,
so a checkout that came down from the last guest keeps the files that it
serves.  The guest test asks C<make -q> whether any is still missing.

The guest test asks tCMS for its front page.  tCMS offers the page that
registers the first user only until it answers its first request, which
touches F<config/setup>.  So when that flag was not there before the test, the
test runs the C<reset> target of F<Installer.mk> and restarts tCMS.  A fresh
guest is then offered the setup page again.  A checkout that came down from
the last guest already has the flag, and the test leaves it alone.

TODO: let the configuration name a commit to check out (#223).

tCMS builds with Dist::Zilla, so the C<dzil> step of the C<perl> recipe
installs the modules that the F<dist.ini> of the checkout names.  tCMS
requires C<Sys::Virt>, so this recipe installs it before the other modules
that the checkout needs.  It pins the version that pkg-config reports for the
libvirt of the guest.  Without the pin, cpm takes the newest, and its build
wants a libvirt far newer than the distribution ships.
L<Provisioner::Recipe::trogrunner> pins it for the same reason.

=head2 A SITE BEHIND A RELAY

A relay caches the pages of a public name, so a site behind one keeps its
logins on another name, which passes through.  See
L<Provisioner::Recipe::nginx/Cached names>.  tCMS needs both names:
C<general.hostname> is the domain, where it sends readers, and
C<general.secure_host> is C<secure_host>, where it sends every page that needs
a login.

When C<secure_host> is set, the fragment queues F<bin/tcms-hostname> of the
checkout to write both into F<config/main.cfg>, as the service user.  It is the
one change that this recipe makes to a checkout that is already there, and
only these two settings.  It runs after the C<perl> recipe has built the
modules that tCMS loads, and before the service of tPSGI starts.  The
F<bin/tcms-hostname> of the checkout must take C<--secure>, which a checkout
older than that does not, and then the task fails.

The guest test asks tCMS for F</login> on the domain, and expects a redirect
to C<secure_host>.

=head2 THE JOB WORKER

tCMS transcodes the videos that users upload in a Minion queue, and a
separate process works that queue.  The recipe installs it as the unit
C<tcms-worker-E<lt>domainE<gt>.service>.  The unit runs
C<bin/tcms-jobs minion worker -j worker_jobs> in the checkout, as the service
user, with the perl that the C<perl> recipe built.  systemd restarts it on
failure.

The unit starts after the service of tPSGI, which is named for the domain.  The
worker saves the posts that it transcodes, so it needs the checkout in place,
and it is useful only while tCMS serves.  The guest test asks systemd whether
the unit is active, and whether C<ffmpeg> runs.  C<ffmpeg> is one of the system
packages that tCMS declares, below, and this recipe names no package for it.

=head2 THE SYSTEM PACKAGES

tCMS declares the system packages that it needs under C<x_system_packages> in
the F<metamerge.yml> of its repository, one for each dependency, and the
archives that some of them come from under C<x_system_sources>.  See
L<Dist::Conformance::Check::SystemPackages>.  So the recipe names no package
itself: C<deps> of the subclass for a distribution asks C<declared_packages>
for those of its packager, and the guest installs them at first boot, before
the C<perl> recipe builds the modules of the checkout against them.  An archive
that tCMS declares for the guest goes to C<package_sources> of the subclass,
with the fingerprint of its key, and first boot adds it before it installs.

They are read when the configuration is generated, from C<repo_branch> of
C<repo_url>, and not from the checkout on the guest.  A guest that keeps the
checkout of the guest before it, as C<remote_files> says, gets the packages
that the branch declares now, and not those of the commit that it serves.

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            repo_url => {
                type             => 'string',
                default          => $DEFAULT_REPO,
                pattern          => q{^(?:(?:https?|ssh|git|file)://\S+|[^/\s@]+@[A-Za-z0-9][A-Za-z0-9.-]*:\S+)$},
                'x-errorMessage' => { pattern => 'is not a git remote: an https, ssh, git or file URL, or user@host:path' },
                description      => 'The git repository to clone tCMS from, which declares its system packages.',
            },
            repo_branch => { type => 'string',  default => 'master',   pattern     => q{^[A-Za-z0-9_.][A-Za-z0-9_./-]*$}, description => 'The branch of repo_url that a new guest clones, and whose metamerge.yml names the system packages.' },
            worker_jobs => { type => 'integer', default => 1,          minimum     => 1,                                  description => 'How many jobs the Minion worker of tCMS runs at once.  A job is one video transcode, and each one uses every core it can.' },
            secure_host => { type => 'string',  format  => 'hostname', description => 'The name that carries the logins of a site behind a relay, and that the relay passes through.  tCMS then sends the pages that need a login there, and readers to the domain.' },
        },
    );
}

=head2 $resolved = $recipe->declared_for(\%host, %opts)

What F<metamerge.yml> on C<repo_branch> of C<repo_url> in C<%opts>, or on the
default of each, declares for C<%host>, as
L<Dist::Conformance::Check::SystemPackages/resolve> returns it: C<needs>,
C<packages>, C<sources>, C<programs> and C<unresolved>, which is empty.  C<%host> is what C<resolve> takes: C<packager>,
C<distro>, C<release> and C<codename>.  Each source has its C<fingerprint>,
which L<Provisioner::Packager::Deb> holds its key to.

It reads the file once for each repository and branch in each process, with
C<fetch>, and resolves it for each call.

It dies rather than return no packages, because tCMS does not run without
them, and a guest without them fails long after the generation: when the file
cannot be read, with what git said; when the branch has no
F<metamerge.yml>; when the declaration is not valid, or cannot be resolved for
the host, with what L<Dist::Conformance::Check::SystemPackages> said about it;
when it declares no dependency at all; and when a dependency has no package of
the packager for the host, naming each.  A dependency that the declaration
gives no package on the host, with a null, is not an error, because the
declaration says so for that host.

=cut

sub declared_for ( $self, $host, %opts ) {    ## no critic (ProhibitMisplacedMethods) -- the subclass of every distribution answers deps and package_sources with it, and Ubuntu is the only one yet
    my $repo   = $opts{repo_url}    // $DEFAULT_REPO;
    my $branch = $opts{repo_branch} // 'master';
    my $where  = "$Dist::Conformance::Check::SystemPackages::FILE on $branch of $repo";

    state %declared;
    my $declaration = $declared{"$repo\n$branch"} //= do {
        my $content  = $self->fetch( $repo, $branch ) // die "tcms: there is no $where, so tCMS declares no system packages, and the guest would install none of what it needs.\n";
        my $snapshot = Dist::Conformance::Snapshot::Tree->new(
            paths => { $Dist::Conformance::Check::SystemPackages::FILE => Dist::Conformance::Snapshot::blob_sha($content) },
            fetch => sub ($) { return $content },
        );
        eval { Dist::Conformance::Check::SystemPackages->declared($snapshot) } // die "tcms: the system packages of tCMS at $where: $@";
    };

    die "tcms: $where declares no system packages, so the guest would install none of what tCMS needs.\n" unless %{ $declaration->{packages} };
    my $resolved = eval { Dist::Conformance::Check::SystemPackages->resolve( $declaration, %$host ) } // die "tcms: the system packages of tCMS at $where: $@";
    die "tcms: $where names no $host->{packager} package for $host->{distro} $host->{release} for " . join( ', ', @{ $resolved->{unresolved} } ) . ", so the guest would lack what tCMS needs.\n"
      if @{ $resolved->{unresolved} };
    return $resolved;
}

=head2 $content = $recipe->fetch($repo, $branch)

The content of F<metamerge.yml> on C<$branch> of the git repository C<$repo>,
or undef when the branch has none.  It clones the branch with git, one commit
deep, with no checkout and no other file, so it reads from any host that git
reaches.  git asks no password, because nobody is there to answer.  Dies with
what git said when it cannot clone.  The one place this recipe reaches the
network, so a test replaces it.

=cut

sub fetch ( $, $repo, $branch ) {
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    my $dir  = File::Temp->newdir;
    my $file = $Dist::Conformance::Check::SystemPackages::FILE;
    my $err  = q{};

    IPC::Run3::run3( [ qw{git clone --quiet --depth 1 --single-branch --no-checkout --filter=blob:none --branch}, $branch, '--', $repo, "$dir/repo" ], \undef, \undef, \$err );
    die "tcms: could not clone $branch of $repo: " . ( ( split m/\n/, $err )[0] // 'git exited with ' . ( $? >> 8 ) ) . "\n" if $?;

    IPC::Run3::run3( [ 'git', '-C', "$dir/repo", 'cat-file', '-e', "HEAD:$file" ], \undef, \undef, \undef );
    return if $?;

    IPC::Run3::run3( [ 'git', '-C', "$dir/repo", 'show', "HEAD:$file" ], \undef, \my $content, \$err );
    die "tcms: could not read $file on $branch of $repo: " . ( ( split m/\n/, $err )[0] // q{} ) . "\n" if $?;
    return $content;
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
                    { pin  => { module => 'Sys::Virt', pkgconfig => 'libvirt' } },
                    { dzil => Path::Tiny::path( @perl_opts{qw{install_dir domain}}, 'tCMS' )->stringify },
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

sub template_files {
    return ( 'tcms-worker.service.tt' => 'tcms-worker.service' );
}

sub tests {
    return qw{tcms.tt};
}

=head2 @hosts = $recipe->fetch_hosts(%opts)

The host of C<repo_url>, which serves the tCMS checkout this recipe clones, and
the hosts that the C<prereq-frontend> target of F<Installer.mk> downloads from.

=cut

sub fetch_hosts ( $, %opts ) {
    return ( Provisioner::Utils::host_of( $opts{repo_url} // $DEFAULT_REPO ), qw{raw.githubusercontent.com cdn.jsdelivr.net} );
}

1;
