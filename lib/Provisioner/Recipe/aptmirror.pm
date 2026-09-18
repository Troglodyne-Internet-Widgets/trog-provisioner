package Provisioner::Recipe::aptmirror;

#ABSTRACT: Mirror a distribution's archive, and serve it to the rest of the fleet.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::aptmirror - a guest that holds a copy of the archive, so
the other guests do not fetch the same packages over the internet.

=head1 SYNOPSIS

    aptmirror.example.test:
        _global:
            size: 161061273600
        aptmirror:
            releases: [noble]
            pockets:  ['', '-updates', '-security']

When the first sync is complete, point the fleet at the mirror:

    _base:
        _global:
            mirror: aptmirror.example.test

=head1 DESCRIPTION

This recipe installs C<apt-mirror> and configures it for the releases and
components you name.  It serves the copy over HTTP and refreshes it on a
schedule.  The C<mirror> argument of L<Provisioner::DistroRecipe> is the other
half.  It tells a guest to use the mirror, and you configure it separately.

=head2 Nothing depends on this

No recipe puts C<aptmirror> in its C<required_recipes>, and no recipe must.  A
mirror is an optimization.  An installation opts into it when it names this
recipe for one domain.  If another recipe required it, every guest that uses
that recipe also needs a mirror host with several hundred gigabytes of Ubuntu.

The relation goes the other way, through the configuration.  A guest names a
mirror, and the mirror does not know its guests.

=head2 It wants a guest of its own

There are two reasons.  Neither one is fatal.  First, the vhost answers for the
B<address> of the guest as well as its name.  A guest that fetches packages has
an address but no resolver yet.  Thus the vhost takes requests that no other
server matches.  Second, the guest is sized for an archive, and the archive
fills any disk that it shares.

=head2 How big

These sizes come from a real mirror of C<noble> on amd64.  They are not
estimates:

    noble             main    8.3 GB
    noble-updates     main   65.2 GB
    noble-security    main   62.5 GB
    noble-backports   main    0.4 GB
    ------------------------------
    main, all four pockets    136 GB

    everything: all components, all architectures, with sources     927 GB

C<sources> is off by default.  It is most of the difference between a mirror
that fits on an ordinary disk and one that does not.  The C<size> of the C<vm>
recipe defaults to 40 GB, which is too small for any row above.  Thus a mirror
host must set its own size.  The guest test fails on a disk that clearly cannot
hold a mirror.  See C<require_free_gb>.

=head2 Seeding from a mirror you already have

C<upstream> defaults to the archive of the distribution.  Another mirror is much
faster.  A copy on the LAN measured about 1.85 GB/s here, and the internet
measured 24 MB/s.  This works because a mirror is a byte-for-byte copy.  It
serves the same C<InRelease>, C<Release>, C<Release.gpg> and C<Packages.gz> as
the archive, so no client can tell the difference.

For a given spool, you cannot go back.  C<apt-mirror> stores under
C<< <spool>/mirror/<upstream host><path> >>.  If you change C<upstream> later,
it does not move the tree.  It starts a second tree next to the first and
downloads everything again.  Seed from the fast source and keep it, or accept a
slow first sync.

=head2 The first sync does not block the build

A full mirror takes hours and hundreds of gigabytes.  C<bin/provision> waits at
most ninety minutes for the makefile and the deferred work.  Thus the sync is a
systemd unit, and the fragment starts it with C<--no-block>.  The makefile
finishes, the tests of the guest run, the provision completes, and the sync
continues after it.

As a result, B<a new mirror host is empty, and that is not a fault>.  Here
are four ways to see its progress, from the most distant to the nearest:

=over 4

=item * C<< curl http://<mirror>/mirror-status >> gives the time of the last
complete sync.  It gives a 404 while the first sync runs.

=item * C<journalctl -u apt-mirror -f> on the guest.

=item * The provision log, which holds the lines that the fragment printed.

=item * Nothing uses the mirror until somebody configures C<mirror> and
provisions again.  Thus no guest moves onto an unfinished mirror without notice.

=back

The unit is the only definition of "sync".  The makefile, the cron and an
operator all start the same unit.  systemd does not run two copies at once.
Thus a refresh that starts during a long sync waits in the queue.  It does not
run a second C<apt-mirror> over the same spool.

=head2 What is not here, on purpose

B<No C<remote_files>, no C<restores>, no C<datadirs>.>  Salvage goes into the
data directory of the domain.  From there it goes into C<data.tar.gz> and into
every backup of it.  This mirror is hundreds of gigabytes of files that the
archive holds and that a new sync can fetch again.  Thus a rebuilt mirror syncs
again.

For the same reason, the spool is B<outside> C<install_dir>.  It is the one
place where this tree breaks that convention on purpose.  The C<data> target
applies chown and chmod to C<< install_dir/<domain> >> recursively on every
provision.  On a few million files, that adds hours to every build.

=head1 METHODS

=head2 $bool = $recipe->is_multi_tenant()

False.  A machine holds one mirror: one F</etc/apt/mirror.list>, one unit and
one cron entry, each at a fixed path.  The releases it carries are an argument
of this domain.  If two domains name different releases, the first one built
decides.  The other domain then gets a mirror of releases it did not ask for.

The vhost is not the problem, because its name comes from the domain.  Each
domain gets its own vhost.  The mirror behind them is what they share.

=cut

sub is_multi_tenant { return 0 }

=head2 %args = $recipe->args()

C<bin/recipes aptmirror> shows each argument, its default and its description.
Three of them have reasons that the descriptions do not give:

=over 4

=item * C<releases> is B<required>, and has no default on purpose.  A wrong
guess costs a few hundred gigabytes of the wrong releases.  Also, a default
here means that this recipe knows its distribution, which is the job of the
distro recipe.

=item * C<pockets> includes C<-security> by default.  A mirror without it
fails quietly, and this recipe exists to remove costs of that kind.

=item * C<require_free_gb> defaults to 50, which is not the size of a real
mirror.  A 40 GB disk cannot have 50 GB free.  Thus a guest left on the 40 GB
default of the C<vm> recipe fails at once.  A small mirror on purpose still
passes.

=back

=cut

sub args {
    return (
        type       => 'object',
        required   => ['releases'],
        properties => {
            releases => {
                type        => 'array',
                items       => { type => 'string' },
                description => 'Releases to mirror, by codename -- noble, jammy.  Required: mirroring the wrong one is several hundred gigabytes of the wrong thing.',
            },
            pockets => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [ q{}, qw{-updates -security -backports} ],
                description => 'Pockets of each release to mirror.  The empty string is the release itself.',
            },
            components => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [qw{main restricted universe multiverse}],
                description => 'Archive components.  Dropping the ones you do not install from is the cheapest way to make a mirror smaller: main alone is a fraction of the whole.',
            },
            arches => {
                type        => 'array',
                items       => { type => 'string' },
                default     => ['amd64'],
                description => 'Architectures to mirror.',
            },
            sources => {
                type        => 'boolean',
                default     => 0,
                description => 'Mirror source packages as well as binaries.  Off, because it roughly doubles the size and almost nothing installs from it.',
            },
            upstream => {
                type        => 'string',
                default     => 'http://archive.ubuntu.com/ubuntu',
                description => 'Where to mirror from.  Another mirror is far faster than the archive and serves an identical tree -- but the spool is laid out under the upstream host name, so changing this later re-downloads everything rather than moving it.',
            },
            path => {
                type        => 'string',
                default     => '/ubuntu',
                description => 'URL path this mirror is served under.  Must match what a guest expects, which is the distro recipe mirror_path.',
            },
            spool => {
                type        => 'string',
                default     => '/var/spool/apt-mirror',
                description => 'Where the copy lives.  Outside install_dir on purpose: the data target walks install_dir recursively on every provision.',
            },
            refresh => {
                type        => 'string',
                default     => '15 2 * * *',
                pattern     => '\A\S+\s+\S+\s+\S+\s+\S+\s+\S+\z',
                description => 'Cron schedule for the refresh, in the five usual fields.',
            },
            nthreads => {
                type        => 'integer',
                default     => 8,
                minimum     => 1,
                description => 'How many downloads apt-mirror runs at once.',
            },
            require_free_gb => {
                type        => 'integer',
                default     => 50,
                minimum     => 0,
                description => 'Free space, in GB, the guest test insists on.  Sized to catch a mirror left on the default disk rather than to fit a real archive.  Zero turns the check off.',
            },
            ipv6 => {
                type        => 'boolean',
                default     => 1,
                description => 'Listen on IPv6 as well.',
            },
            backlog => {
                type        => 'integer',
                default     => 32768,
                minimum     => 0,
                description => 'listen() backlog for the vhost.',
            },
        },
    );
}

=head2 %required = $recipe->required_recipes()

C<nginx>, which serves the copy.  C<ufw> comes in through nginx, because nginx
declares rate limits for ports 80 and 443.

=cut

sub required_recipes {
    return ( nginx => sub { return () } );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'aptmirror.mirror.list.tt'   => 'aptmirror.mirror.list',
        'aptmirror.service.tt'       => 'aptmirror.service',
        'aptmirror.postmirror.sh.tt' => 'aptmirror.postmirror.sh',
        'aptmirror.cron.tt'          => 'aptmirror.cron',
        'aptmirror.nginx.conf.tt'    => 'aptmirror.nginx.conf',
    );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('aptmirror.tt') }

=head2 %opts = $recipe->enrich(%opts)

Adds C<upstream_host>, C<mirror_root> and C<suites> to C<%opts>, and returns
them.  Dies when C<upstream> is not a URL with a path.

C<apt-mirror> puts a spool at C<< <spool>/mirror/<upstream host><path> >>.
Thus the directory that nginx serves comes from C<upstream>, and a fixed path
cannot replace it.  The vhost and the fragment must both use C<mirror_root>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my ( $host, $path ) = $opts{upstream} =~ m{\A[[:alpha:]][[:alnum:]+.-]*://([^/]+)(/\S*)\z};
    die "upstream must be a URL with a path on it, like http://archive.ubuntu.com/ubuntu -- got '$opts{upstream}'\n"
      unless defined $host && defined $path;

    $path =~ s{/\z}{};
    $opts{upstream_host} = $host;
    $opts{mirror_root}   = "$opts{spool}/mirror/$host$path";

    # Every release with every pocket: apt-mirror wants a line for each, and the
    # guest test counts them.
    $opts{suites} = [
        map {
            my $release = $_;
            map { "$release$_" } @{ $opts{pockets} }
        } @{ $opts{releases} }
    ];

    return %opts;
}

1;
