package Provisioner::Recipe::fetchcache;

#ABSTRACT: Keep what the fleet downloads, so a provision does not wait on upstream, or stop when it fails.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Data::Validate::Domain();
use List::Util();
use File::Slurper();
use IO::Socket::SSL::Utils();

use Provisioner::Cookbook();
use Provisioner::Utils();
use Trog::Config();
use Trog::Utils();

=head1 NAME

Provisioner::Recipe::fetchcache - a pull-through cache for what guests download
while they provision, so an upstream outage stops being a failed build.

=head1 SYNOPSIS

    fetchcache.test:
        fetchcache: {}

and then point the fleet at it:

    _base:
        _global:
            cache: fetchcache.test

=head1 DESCRIPTION

An nginx that answers for the hosts recipes download from -- C<www.cpan.org>,
C<github.com>, C<codeload.github.com> -- fetches from the real ones on a guest's
behalf, and keeps what it fetched.

A guest reaches it by those names.  While a guest provisions, each host its
recipes list in C<fetch_hosts> is pointed at the cache in its F</etc/hosts>, and
the authority the cache's certificate is signed by is in its trust store; both
are taken back out once its deferred work is done.  So nothing that downloads has
to know there is a cache -- a URL in a template, cpanm, git and pip all fetch
C<https://github.com/...> as written, and are answered from here -- and a host
no recipe named goes straight upstream as it always did.  See C<fetch_hosts> in
L<Provisioner::Recipe>, C<cache> in L<Provisioner::DistroRecipe>, and
F<scripts/fetch_via_cache>, which is the guest's half.

A host is pointed at the cache only if the cache answers for it when the guest
starts, asked by that name over TLS at C</fetchcache-status>.  So a cache that
is down, or that does not fetch from a host some recipe names, costs a build
nothing.  One that dies partway through a build does: what was pointed at it
stays pointed at it until the build ends.

=head2 Pull-through, and stale rather than failing

Nothing is fetched until a guest asks for it, and what has been fetched is kept
until the store runs out of room -- see L</When it runs out of room>.  When
upstream fails -- an error, a timeout, or a 403, 404, 429 or 5xx -- a copy the
cache already has is served instead, however old.  That is the point of it:
GitHub answering 503 for an hour is an hour of builds that did not notice.

A 404 is on that list on purpose.  CPAN moves superseded releases off to BackPAN
and a project can delete a release, and a pinned build still wants the version
it was pinned to.  The cache keeps every version it has ever handed out.

=head2 Three kinds of URL, and one it does not keep

How long a copy is used before upstream is asked again depends on what the URL
is, which the recipe knows from the host and the path -- see C<classes>:

=over 4

=item * B<index> -- what says which version is current: CPAN's C<modules/>,
MetaCPAN's API, GitHub's API, and a C<releases/latest> link.  C<fresh_index>,
ten minutes by default, so a new release is picked up the same afternoon.

=item * B<immutable> -- what a version number or a commit names, and so never
changes: CPAN's C<authors/id/>, a GitHub release asset or a commit archive,
garage's and ImageMagick's release downloads.  C<fresh_immutable>, a year.  A
branch archive is not one of these: C<archive/refs/heads/> moves.

=item * B<default> -- anything else on an allowed host.  C<fresh_default>, an
hour.

=back

Only a C<200> is kept.  Upstream's own C<Cache-Control> is ignored, because
GitHub marks every release asset C<private> and would otherwise never be cached
at all.

A copy that is no longer fresh is not thrown away: upstream is asked whether it
has changed, with the copy's C<ETag> or C<Last-Modified>, and a C<304> keeps it.
So a year's freshness for what never changes costs one small request a year,
and an upstream that is down or has dropped the file gets the copy served
instead.

What is B<never kept> is passed upstream as it came, credentials and all, and
its answer passed back: a request that is not a C<GET> or C<HEAD>, and git's
smart-HTTP ref advertisement (C<$PASSTHROUGH>), which says where each branch is
now.  So a C<git clone> from a host some recipe named still works, and still
clones what is there today.

=head2 When it runs out of room

Nothing is removed for its age: C<inactive> defaults to a hundred years, so a
copy nobody has asked for in a long time is still there for the build that
finally does.  Those are the ones that matter most -- a guest rebuilt a year on,
pinned to a Sys::Virt or a garage upstream has since moved to BackPAN or
deleted -- and nothing can fetch them back.

What removes anything is room.  When the store passes C<max_size_gb>, or the
disk it is on has less than C<min_free_gb> free, nginx's cache manager removes
the least recently used copies until it is back under.  Least recently used
rather than first in, first out: the oldest copy is often the old pinned
version every build still asks for, and first-in-first-out would throw that
away first.  C<max_size_gb> is enforced lazily and can be briefly exceeded,
which is what C<min_free_gb> is there for: the store is on the guest's root
disk.

=head2 Redirects are followed here

A GitHub release asset is a redirect to a signed URL on another host that stops
working within minutes, so a guest handed the redirect would cache nothing
useful.  The cache follows it instead, and keeps the body under the URL the guest
asked for.  It follows only to a host in C<upstreams>, and only over https;
anything else is a C<502>.

=head2 The certificate, and who signs it

The cache presents one certificate naming every host it fetches from, signed by
an authority this installation makes the first time it needs one and keeps in
its configuration directory beside F<ips.db>, as F<fetchcache-ca.crt> and
F<fetchcache-ca.key> -- see L<Trog::Config>.  C<bin/new_config> signs a new
certificate each time it configures the cache, and hands the authority's
certificate, never its key, to every guest that provisions through it.

That authority can vouch for any name at all, which is why a guest trusts it
only while it provisions, and why its key never leaves the machine that runs the
provisioner.  Delete both files to replace it: the next configuration makes a
new one, which the cache and each guest take up when they are next built.  A
scratch configuration has an authority of its own.

=head2 What a guest has to trust

A guest provisioning through the cache takes what it serves for upstream's, so
the cache is a trust point: what it serves is what gets built.  What keeps that
narrow is that it only fetches from C<upstreams>, over TLS it verifies against
the system's certificate authorities, and never forwards a guest's
C<Authorization> or C<Cookie> with anything it keeps -- so nothing it keeps was
fetched as anybody in particular.

=head2 Sharing a port with a package mirror

It listens on 443 and on 80 -- a guest pointed at it by name asks on whatever
port it likes, and cpanm asks CPAN over plain http -- and answers only to the
names of the hosts it fetches from.  Upstream is fetched over https whichever
port the guest asked on.

That it answers by name and not by address is what lets it B<coexist> with an
L<Provisioner::Recipe::aptmirror> on one guest, neither being told about the
other: nginx routes a port between servers by name, and fetchcache leaves 80's
C<backlog>, which nginx takes once a port, to the mirror.  Worth knowing about,
rather than recommended.  A mirror is there to be a mirror, and a cache is all
that a provision needs to be quick and to survive a bad day upstream, so most
installations should keep them apart.

Nothing else is answered.  A guest reaching one of those hosts on another port
while it provisions -- git over ssh to C<github.com> -- reaches the cache
instead, and fails.

    mirrors.test:
        aptmirror:
            releases: [noble]
        fetchcache: {}

    _base:
        _global:
            mirror: mirrors.test
            cache:  mirrors.test

=head2 Seeing what it did

Every response carries C<X-Cache-Status> -- C<MISS>, C<HIT>, C<STALE>,
C<UPDATING>, C<EXPIRED>, C<REVALIDATED> -- and F</var/log/nginx/fetchcache.log>
records the same for every request, with the host it was for.  To ask it
something from anywhere, name the host and give its address:

    curl -skI --resolve www.cpan.org:443:<cache address> \
        https://www.cpan.org/modules/02packages.details.txt.gz

(C<-k>, because only a guest that is provisioning trusts the authority.)

Nothing requires it.  A fleet with no cache configured downloads straight from
upstream, as it always has.

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<upstreams> -- the hosts it will fetch from, each true or false.  The
defaults are every host a recipe names in C<fetch_hosts>, each on; naming
another adds it, and naming one of the defaults false turns it off.

=item * C<store>, C<max_size_gb>, C<min_free_gb>, C<inactive> -- where copies are
kept, how much of the disk they may take, how much of it to leave free, and how
long one nobody asks for survives.  See L</When it runs out of room>.

=item * C<fresh_index>, C<fresh_immutable>, C<fresh_default> -- how long a copy
of each kind is used before upstream is asked again.  In nginx's units:
C<10m>, C<1h>, C<365d>.

=back

=cut

sub args {
    my $duration = '\A\d+(?:ms|[smhdwMy])?\z';
    return (
        type       => 'object',
        properties => {

            # On the members rather than on the map, so that an operator adding
            # one host keeps all of these.
            upstreams => {
                type    => 'object',
                default => {},

                # What every recipe names by default, and what the domains this
                # installation actually configures will reach: a koan pointed at
                # a gitea of its own is a host this cache has to answer for, and
                # asking the class alone never saw it.
                properties           => { map { $_ => { type => 'boolean', default => 1 } } List::Util::uniq( sort Provisioner::Cookbook->fetch_hosts, Provisioner::Cookbook->configured_fetch_hosts ) },
                additionalProperties => { type => 'boolean' },
                description          => 'Hosts the cache will fetch from, each true or false.  The defaults are every host a recipe names in fetch_hosts; naming another adds it, and naming a default false removes it.',
            },
            store => {
                type        => 'string',
                default     => '/var/cache/fetchcache',
                description => 'Where copies are kept.  Outside install_dir on purpose: the data target walks install_dir recursively on every provision.',
            },
            max_size_gb => {
                type        => 'integer',
                default     => 20,
                minimum     => 1,
                description => 'How much of the disk copies may take, in GB.  nginx enforces it lazily, so the store can briefly exceed it.',
            },
            min_free_gb => {
                type        => 'integer',
                default     => 5,
                minimum     => 0,
                description => 'Free space, in GB, to leave on the disk the store is on.  Below it the least recently used copies are removed, whatever max_size_gb says.  Zero turns it off.',
            },
            inactive => {
                type        => 'string',
                default     => '100y',
                pattern     => $duration,
                description => 'How long a copy nobody asks for is kept.  A hundred years by default, so that only running out of room removes anything: the copy nobody has asked for in a year is the pinned version upstream may no longer have.',
            },
            fresh_apt_index => {
                type        => 'string',
                default     => '5m',
                pattern     => $duration,
                description => 'How long an apt index is used before the repository is asked again.  Short, and never served stale: InRelease names the hashes of the Packages beside it, and a mismatched pair stops apt outright.',
            },
            fresh_index => {
                type        => 'string',
                default     => '10m',
                pattern     => $duration,
                description => 'How long an index -- which version is current -- is used before upstream is asked again.',
            },
            fresh_immutable => {
                type        => 'string',
                default     => '365d',
                pattern     => $duration,
                description => 'How long a file a version or a commit names is used before upstream is asked again.  These never change.',
            },
            fresh_default => {
                type        => 'string',
                default     => '1h',
                pattern     => $duration,
                description => 'How long anything else is used before upstream is asked again.',
            },
            ipv6 => {
                type        => 'boolean',
                default     => 1,
                description => 'Listen on IPv6 as well.',
            },
        },
    );
}

=head2 @classes = $recipe->classes()

The kinds of URL, most specific first: C<index> for one saying which version is
current, C<immutable> for one a version or a commit names, and C<default> for
whatever the other two did not take.  Each is a C<name>, the C<args> key saying
how fresh a copy of that kind stays, and a C<pattern> matched against
C<HOST/PATH>.

The patterns are not held here.  Each recipe declares its own in
C<cache_classes> -- see L<Provisioner::Recipe> -- and this is the union of them,
so a recipe gaining an upstream is not a reason to edit the cache.  What stays
here is C<default>, which belongs to no recipe, and C<$PASSTHROUGH>.

=cut

our @CLASS_ORDER = (

    # First, and the only one that refuses to be served stale: an apt index is
    # half of a pair, and half of a pair from a different moment is a hash-sum
    # mismatch rather than an old download.
    { name => 'aptindex',  fresh => 'fresh_apt_index', no_stale => 1 },
    { name => 'index',     fresh => 'fresh_index' },
    { name => 'immutable', fresh => 'fresh_immutable' },
);

sub classes {
    my ($self) = @_;

    my %pattern;
    push( @{ $pattern{ $_->{class} } }, $_->{pattern} ) for Provisioner::Cookbook->cache_classes;

    # Sorted and once each: two recipes downloading from one upstream describe it
    # the same way, and the vhost this renders into should not change because the
    # recipes were loaded in a different order.
    my @classes = map {
        my @patterns = List::Util::uniq( sort @{ $pattern{ $_->{name} } // [] } );
        @patterns ? { %$_, pattern => join( '|', @patterns ) } : ();
    } @CLASS_ORDER;

    return ( @classes, { name => 'default', fresh => 'fresh_default' } );
}

=head2 $PASSTHROUGH

The pattern of what is never kept, matched the same way and ahead of the
classes: git's smart-HTTP ref advertisement.

=cut

our $PASSTHROUGH = '[^/]+/.+/info/refs\?service=git-';

=head2 %required = $recipe->required_recipes()

C<nginx>, which is what fetches and serves.  C<ufw> arrives behind it, with
nginx's limit on 443, and the nginx profile it allows is what lets the cache
reach 443 upstream.

=cut

sub required_recipes {
    return ( nginx => sub { return () } );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return ( 'fetchcache.nginx.conf.tt' => 'fetchcache.nginx.conf' );
}

=head2 @written = $recipe->generate_files($output_dir, %vars)

The vhost, and the certificate it presents: see C<certify>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated( $self->vars(), %vars );
    return ( @written, $self->certify( $output_dir, @{ $opts{allow} } ) );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('fetchcache.tt') }

=head2 %opts = $recipe->enrich(%opts)

Turns C<upstreams> into C<allow>, the hosts that are on, and C<allow_re>, the
same as a regex alternation; the URL classes into C<classes>, each with the
freshness configured for it; and hands the template C<$PASSTHROUGH>.

Dies on a host that is not a plain DNS name, because it is written into the
vhost as a regex and into a certificate, and on an empty list, which would be a
cache that fetches nothing.

C<resolvers> are the fleet's, less any loopback or IPv6 address, and it dies if
none are left: nginx looks an upstream up when it fetches, and has to be given
servers it can reach.  The fleet's list can lead with C<127.0.0.1>, which is
right on a guest running the pdns recursor and on this one is nothing -- nginx
rotates through the list, so every few lookups was a refused connection.  Not
systemd-resolved's stub instead, which would fail over properly: the
C<nostubresolver> recipe turns it off on these guests.  And IPv6 because nginx
is told C<ipv6=off>, as apt is told to use IPv4.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @allow = sort grep { $opts{upstreams}{$_} } keys %{ $opts{upstreams} };
    die "fetchcache has no upstreams turned on, so it would fetch nothing.\n" unless @allow;

    # is_domain rather than a regex of our own: it refuses a scheme, a path, a
    # space and a leading or trailing dash, and it checks the top-level domain,
    # which a hand-rolled pattern here did not.  Note that last part -- a host
    # under a made-up TLD is refused now, where the pattern took it.
    my @bad = grep { !Data::Validate::Domain::is_domain($_) } @allow;
    die "fetchcache upstreams must be plain host names; these are not: @bad\n" if @bad;

    $opts{allow}       = \@allow;
    $opts{allow_re}    = join( '|', map { quotemeta } @allow );
    $opts{passthrough} = $PASSTHROUGH;
    $opts{classes}     = [
        map {
            { %$_, fresh => $opts{ $_->{fresh} } }
        } $self->classes
    ];

    my @given = @{ Provisioner::Utils::coerce_arrayref( $opts{resolvers} ) };
    $opts{resolvers} = [ grep { !m/\A127\./ && index( $_, ':' ) < 0 } @given ];
    die "fetchcache needs resolvers it can reach to look its upstreams up with, and of '@given' none are left once loopback and IPv6 are taken out.\n"
      unless @{ $opts{resolvers} };

    return %opts;
}

=head2 $paths = Provisioner::Recipe::fetchcache->authority()

The authority the cache's certificate is signed by, as a hash of C<cert> and
C<key>, the paths of the two files.  Made the first time anything asks, and
kept; see L</The certificate, and who signs it>.

=cut

use constant {
    AUTHORITY_DAYS   => 3650,
    CERTIFICATE_DAYS => 397,
    DAY              => 86_400,
};

sub authority {
    my ($class) = @_;

    my %paths = ( cert => Trog::Config->path('fetchcache-ca.crt'), key => Trog::Config->path('fetchcache-ca.key') );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return \%paths if -f $paths{cert} && -f $paths{key};

    my ( $cert, $key ) = IO::Socket::SSL::Utils::CERT_create(
        CA        => 1,
        subject   => { commonName => 'trog-provisioner fetch cache authority' },
        not_after => time + AUTHORITY_DAYS * DAY,
        key       => IO::Socket::SSL::Utils::KEY_create_ec('prime256v1'),
    );

    # The key first: the pair is only taken as made once both are there.
    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    Trog::Utils::write_pem( $paths{key},  IO::Socket::SSL::Utils::PEM_key2string($key),   0600 );
    Trog::Utils::write_pem( $paths{cert}, IO::Socket::SSL::Utils::PEM_cert2string($cert), 0644 );
    ## use critic

    IO::Socket::SSL::Utils::CERT_free($cert);
    IO::Socket::SSL::Utils::KEY_free($key);

    return \%paths;
}

=head2 @written = $recipe->certify($output_dir, @hosts)

Sign a certificate naming C<@hosts> with the C<authority>, and write it into
C<$output_dir> as F<fetchcache.crt>, with the authority's after it, and its key
as F<fetchcache.key>.  Signed afresh each time, and good for a little over a
year, which is as long as a client will take one for.

=cut

sub certify {
    my ( $self, $output_dir, @hosts ) = @_;

    my $authority = $self->authority;
    my $ca_cert   = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $ca_key    = IO::Socket::SSL::Utils::PEM_file2key( $authority->{key} );

    my ( $cert, $key ) = IO::Socket::SSL::Utils::CERT_create(
        subject   => { commonName => $hosts[0] },
        purpose   => 'server',
        issuer    => [ $ca_cert, $ca_key ],
        not_after => time + CERTIFICATE_DAYS * DAY,
        key       => IO::Socket::SSL::Utils::KEY_create_ec('prime256v1'),
        ext       => [ { sn => 'subjectAltName', data => join( ',', map { "DNS:$_" } @hosts ) } ],
    );

    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    Trog::Utils::write_pem( "$output_dir/fetchcache.key", IO::Socket::SSL::Utils::PEM_key2string($key),                                                    0600 );
    Trog::Utils::write_pem( "$output_dir/fetchcache.crt", IO::Socket::SSL::Utils::PEM_cert2string($cert) . File::Slurper::read_text( $authority->{cert} ), 0644 );
    ## use critic

    IO::Socket::SSL::Utils::CERT_free($_) for $cert, $ca_cert;
    IO::Socket::SSL::Utils::KEY_free($_)  for $key,  $ca_key;

    return qw{fetchcache.crt fetchcache.key};
}

1;
