package Provisioner::Recipe::aptmirror;

#ABSTRACT: Mirror a distribution's archive, and serve it to the rest of the fleet.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 NAME

Provisioner::Recipe::aptmirror - a guest that holds a copy of the archive, so
every other guest stops fetching the same packages over the internet.

=head1 SYNOPSIS

    aptmirror.example.test:
        _global:
            size: 161061273600
        aptmirror:
            releases: [noble]
            pockets:  ['', '-updates', '-security']

and then, once it has synced, point the fleet at it:

    _base:
        _global:
            mirror: aptmirror.example.test

=head1 DESCRIPTION

Installs C<apt-mirror>, configures it for the releases and components asked for,
serves the result over HTTP, and refreshes it on a schedule.  What a guest does
with that is L<Provisioner::DistroRecipe>'s C<mirror>, which is the other half
and is configured separately.

=head2 Nothing depends on this

No recipe puts C<aptmirror> in its C<required_recipes>, and none should.  A
mirror is an optimisation an installation opts into by naming this recipe for
one domain; making anything require it would drag a mirror host into every
guest's dependency graph and turn "I would like to build a web server" into "I
would like to build a web server and several hundred gigabytes of Ubuntu".

The relationship runs the other way and through configuration: a guest names a
mirror, and the mirror does not know who its guests are.

=head2 It wants a guest of its own

Two reasons, neither fatal but both worth knowing before putting this beside
something else.  Its vhost answers for the guest's B<address> as well as its
name, because a guest fetching packages has an address and not yet a resolver --
so it takes requests that would otherwise go unmatched.  And it is sized for an
archive, so it will fill any disk it shares.

=head2 How big

Measured against a real mirror rather than estimated, for C<noble> on amd64:

    noble             main    8.3 GB
    noble-updates     main   65.2 GB
    noble-security    main   62.5 GB
    noble-backports   main    0.4 GB
    ------------------------------
    main, all four pockets    136 GB

    everything: all components, all architectures, with sources     927 GB

C<sources> is off by default and is most of the difference between a mirror that
fits on an ordinary disk and one that does not.  The C<vm> recipe's C<size>
defaults to 40 GB, which is not enough for any of the above, so a mirror host
has to say how big it is -- and the guest test refuses to pass on a disk that
obviously cannot hold one.  See C<require_free_gb>.

=head2 Seeding from a mirror you already have

C<upstream> defaults to the distribution's archive, but pointing it at another
mirror is far faster -- a LAN copy against the internet, which measured here as
roughly 1.85 GB/s against 24 MB/s.  It works because a mirror is a byte-for-byte
copy: the same C<InRelease>, C<Release>, C<Release.gpg> and C<Packages.gz> the
archive serves, so nothing can tell the difference.

B<It is a one-way door for a given spool.>  C<apt-mirror> stores under
C<< <spool>/mirror/<upstream host><path> >>, so changing C<upstream> later does
not move the tree -- it starts a second one beside it and downloads everything
again.  Seed from the fast thing and stay there, or take the slow first sync.

=head2 The first sync does not block the build

A full mirror is hours and hundreds of gigabytes, and C<bin/provision> allows
ninety minutes for the makefile and the deferred work together.  So the sync is
a systemd unit and the fragment starts it with C<--no-block>: the makefile
finishes, the guest's tests run, the provision completes, and the sync carries
on afterwards.

Which means B<a fresh mirror host is empty and that is not a fault>.  Four ways
to see where it got to, from furthest away in:

=over 4

=item * C<< curl http://<mirror>/mirror-status >> -- the timestamp of the last
completed sync, and a 404 while the first one is still running.

=item * C<journalctl -u apt-mirror -f> on the guest.

=item * The provision log, which carries the lines the fragment printed.

=item * Nothing points at it until somebody configures C<mirror> and
re-provisions, so no guest is ever silently moved onto an unfinished mirror.

=back

The unit is also the only definition of "sync": the makefile, the cron and an
operator all start the same one, and systemd will not run two at once, so a
refresh landing during a long sync queues instead of running a second
C<apt-mirror> over one spool.

=head2 What is deliberately not here

B<No C<remote_files>, no C<restores>, no C<datadirs>.>  Salvage lands under the
domain's data directory and from there into C<data.tar.gz> and every backup
taken of it; this is hundreds of gigabytes of files that exist on the archive
and are re-fetchable by definition.  A rebuilt mirror syncs again, which is the
right answer.

For the same reason the spool is B<outside> C<install_dir>, which is the one
place this tree breaks that convention on purpose: the C<data> target chowns and
chmods C<< install_dir/<domain> >> recursively on every provision, and doing
that to a few million files would add hours to every build.

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<releases> -- B<required>, and deliberately without a default.  Which
releases to mirror is not something to guess at when the guess costs a few
hundred gigabytes of the wrong thing, and a default here would mean this recipe
knowing which distribution it is on, which is the distro recipe's job.

=item * C<pockets> -- defaults to the release itself plus C<-updates>,
C<-security> and C<-backports>.  Security is in the default because a mirror
that silently lacks it is exactly the sort of quiet tax this recipe exists to
remove.

=item * C<require_free_gb> -- how much free space the guest test insists on.
Defaults to 50, which is not a real mirror's worth: it is chosen so that a guest
left on the C<vm> recipe's 40 GB default fails immediately, since a 40 GB disk
cannot have 50 GB free.  A deliberately small mirror still passes.

=back

=cut

sub args {
    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
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

C<nginx>, which is what serves the copy.  C<ufw> arrives behind it, since nginx
declares the rate limits for 80 and 443.

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

Works out where the copy will land and which suites it covers.

C<apt-mirror> lays a spool out as C<< <spool>/mirror/<upstream host><path> >>,
so the directory nginx serves cannot be written down -- it follows from
C<upstream>, and the vhost and the fragment both have to name the same one.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my ( $host, $path ) = $opts{upstream} =~ m{\A[a-z][a-z\d+.-]*://([^/]+)(/\S*)\z}i;
    die "upstream must be a URL with a path on it, like http://archive.ubuntu.com/ubuntu -- got '$opts{upstream}'\n"
      unless defined $host && defined $path;

    $path =~ s{/\z}{};
    $opts{upstream_host} = $host;
    $opts{mirror_root}   = "$opts{spool}/mirror/$host$path";

    # Every release crossed with every pocket, which is what apt-mirror wants a
    # line for and what the guest test counts.
    $opts{suites} = [
        map {
            my $release = $_;
            map { "$release$_" } @{ $opts{pockets} }
        } @{ $opts{releases} }
    ];

    return %opts;
}

1;
