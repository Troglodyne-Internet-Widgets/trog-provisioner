package Provisioner::Recipe::fetchcache;

#ABSTRACT: Keep what the fleet downloads, so a provision does not wait on upstream, or stop when upstream fails.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use Data::Validate::Domain();
use List::Util();
use File::Slurper();
use IO::Socket::SSL::Utils();

use Provisioner::Cookbook();
use Provisioner::Utils();
use Trog::Config();

=head1 NAME

Provisioner::Recipe::fetchcache - a pull-through cache for what guests download
while they provision, so an upstream outage does not fail a build.

=head1 SYNOPSIS

    fetchcache.test:
        fetchcache: {}

Then point the fleet at it:

    _base:
        _global:
            cache: fetchcache.test

=head1 DESCRIPTION

This recipe builds an nginx that answers for the hosts that recipes download
from, for example C<www.cpan.org>, C<github.com> and C<codeload.github.com>.  It
fetches from the real hosts for a guest, and it keeps what it fetched.

A guest reaches the cache by those host names.  While a guest provisions, its
F</etc/hosts> points each host in the C<fetch_hosts> of its recipes at the cache.
Its trust store also holds the authority that signs the certificate of the cache.
Both come out again when the deferred work of the guest is done.  cloud-init
sets both at first boot, before it installs the packages, so a package from a
vendor archive comes through the cache as well.  The makefile sets them again.

Thus nothing that downloads has to know about the cache.  A URL in a template,
cpanm, git and pip all fetch C<https://github.com/...> as written, and the cache
answers.  A host that no recipe names goes straight upstream.  See
C<fetch_hosts> in L<Provisioner::Recipe>, C<cache> in
L<Provisioner::DistroRecipe>, and F<scripts/fetch_via_cache>, which is the half
that runs on the guest.

A guest points a host at the cache only if the cache answers for that host when
the guest starts.  The guest asks by that name, over TLS, at
C</fetchcache-status>.  Thus a cache that is down costs a build nothing.  The
same is true of a cache that does not fetch from a host that some recipe names.
A cache that stops partway through a build is different.  What the guest pointed
at it stays pointed at it until the build ends.

=head2 Pull-through, and stale rather than failing

The cache fetches nothing until a guest asks for it.  It keeps what it fetched
until the store runs out of room, see L</When it runs out of room>.  If upstream
fails, the cache serves the copy it has, however old.  A failure is an error, a
timeout, or a 403, 404, 429 or 5xx.  Thus when GitHub answers 503 for an hour,
the builds of that hour do not notice.  An apt index is the exception, see
L</Four kinds of URL, and one it does not keep>.

A 404 is on that list on purpose.  CPAN moves superseded releases to BackPAN,
and a project can delete a release.  A pinned build still wants the version it
is pinned to.  The cache keeps every version that it ever served.

=head2 Four kinds of URL, and one it does not keep

The kind of a URL sets how long the cache uses a copy before it asks upstream
again.  The recipe finds the kind from the host and the path, see C<classes>:

=over 4

=item * C<aptindex>: the indexes of an apt repository.  C<fresh_apt_index>,
five minutes by default.  The cache never serves one stale.  An index is half of
a pair, and a pair from two different moments stops apt with a hash-sum mismatch.

=item * B<index>: a URL that says which version is current.  Examples are the
C<modules/> of CPAN, the API of MetaCPAN, the API of GitHub, and a
C<releases/latest> link.  C<fresh_index>, ten minutes by default, so the cache
sees a new release on the same afternoon.

=item * B<immutable>: a URL that a version number or a commit names, and which
thus never changes.  Examples are the C<authors/id/> of CPAN, a GitHub release
asset or commit archive, and the release downloads of garage and ImageMagick.
C<fresh_immutable>, a year.  A branch archive is not immutable, because
C<archive/refs/heads/> moves.

=item * B<default>: any other URL on an allowed host.  C<fresh_default>, an
hour.

=back

The cache keeps only a C<200>.  It ignores the C<Cache-Control> of upstream,
because GitHub marks every release asset C<private>.  If the cache obeys that,
it never keeps a release asset.

The cache does not discard a copy that is no longer fresh.  It asks upstream if
the file changed, with the C<ETag> or C<Last-Modified> of the copy, and a C<304>
keeps the copy.  Thus a year of freshness costs one small request a year.  If
upstream is down or no longer has the file, the cache serves the copy.

The cache B<never keeps> two kinds of request.  It passes them upstream as they
came, with their credentials, and passes the answer back:

=over 4

=item * A request that is not a C<GET> or C<HEAD>.

=item * The smart-HTTP ref advertisement of git (C<$PASSTHROUGH>), which says
where each branch is now.

=back

Thus a C<git clone> from a host that a recipe names still works, and it clones
what is there today.

=head2 When it runs out of room

The cache removes nothing because of its age.  C<inactive> is a hundred years by
default.  Thus a copy that nobody asked for in a long time is still there for
the build that asks for it.  Those copies matter most, because nothing can fetch
them again.  An example is a guest that is rebuilt a year later and is pinned to
a Sys::Virt or garage release that upstream moved to BackPAN or deleted.

Only lack of room removes a copy.  The cache manager of nginx removes the least
recently used copies in two cases.  One is when the store is larger than
C<max_size_gb>.  The other is when the disk of the store has less than
C<min_free_gb> free.  It removes copies until the store is below the limit again.

The order is least recently used, not first in, first out.  The oldest copy is
often an old pinned version that every build still asks for.  First in, first
out discards that copy first.

nginx enforces C<max_size_gb> lazily, so the store can briefly be larger.
C<min_free_gb> is for that case, because the store is on the root disk of the
guest.

=head2 Redirects are followed here

A GitHub release asset is a redirect to a signed URL on another host.  That URL
stops working within minutes, so a guest that gets the redirect caches
nothing useful.  Thus the cache follows the redirect itself.  It keeps the body
under the URL that the guest asked for.  It follows a redirect only to a host in
C<upstreams>, and only over https.  Any other redirect gets a C<502>.

=head2 The certificate, and who signs it

The cache presents one certificate that names every host it fetches from.  An
authority signs that certificate.  This installation makes the authority the
first time it needs one.  It keeps the authority in its configuration directory
beside F<ips.db>, as F<fetchcache-ca.crt> and F<fetchcache-ca.key>, see
L<Trog::Config>.

C<bin/new_config> signs a new certificate each time it configures the cache.  It
gives the certificate of the authority to every guest that provisions through
the cache.  It never gives out the key of the authority.

The authority can vouch for any name at all.  Thus a guest trusts it only while
the guest provisions, and its key never leaves the machine that runs the
provisioner.  To replace the authority, delete both files.  The next
configuration makes a new one.  The cache and each guest use the new authority
when they are next built.  A scratch configuration has its own authority.

=head2 What a guest has to trust

A guest that provisions through the cache uses what the cache serves in place
of what upstream serves.  Thus the cache is a trust point: what it serves is
what gets built.  Three rules keep that trust narrow:

=over 4

=item * The cache fetches only from C<upstreams>.

=item * It fetches over TLS, which it verifies against the certificate
authorities of the system.

=item * It never forwards the C<Authorization> or C<Cookie> of a guest with a
request whose answer it keeps.  Thus nothing that it keeps was fetched as a
particular user.

=back

=head2 Sharing a port with a package mirror

The cache listens on 443 and on 80.  A guest that is pointed at it by name can
ask on either port, and cpanm asks CPAN over plain http.  The cache answers only
to the names of the hosts it fetches from.  It fetches from upstream over https,
whichever port the guest asked on.

The cache answers by name and not by address.  Thus it can B<coexist> with a
L<Provisioner::Recipe::aptmirror> on one guest, and neither recipe has to know
about the other.  nginx routes a port to a server by name.  nginx takes the
C<backlog> of a port only once, and fetchcache leaves the C<backlog> of port 80
to the mirror.

This arrangement is possible, but it is not recommended.  A mirror is there to
be a mirror.  A cache is all that a provision needs to be quick and to survive a
bad day upstream.  Keep the two on separate guests in most installations.

The cache answers nothing else.  A guest that reaches one of those hosts on
another port while it provisions reaches the cache and fails.  An example is git
over ssh to C<github.com>.

    mirrors.test:
        aptmirror:
            releases: [noble]
        fetchcache: {}

    _base:
        _global:
            mirror: mirrors.test
            cache:  mirrors.test

=head2 Seeing what it did

Every response has an C<X-Cache-Status> header.  Its values are C<MISS>,
C<HIT>, C<STALE>, C<UPDATING>, C<EXPIRED> and C<REVALIDATED>.
F</var/log/nginx/fetchcache.log> records the same value for every request, with
the host of the request.  To ask the cache something from any machine, name the
host and give the address of the cache:

    curl -skI --resolve www.cpan.org:443:<cache address> \
        https://www.cpan.org/modules/02packages.details.txt.gz

Use C<-k>, because only a guest that is provisioning trusts the authority.

The fleet does not need a cache.  A fleet with no cache configured downloads
straight from upstream.

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<upstreams>: the hosts that the cache fetches from, each true or false.
The defaults are every host that a recipe names in C<fetch_hosts>, each true.
Name another host to add it.  Set a default host to false to turn it off.

=item * C<store>, C<max_size_gb>, C<min_free_gb>, C<inactive>: where the cache
keeps copies, how much of the disk they can use, how much of the disk to leave
free, and how long a copy that nobody asks for stays.  See
L</When it runs out of room>.

=item * C<fresh_apt_index>, C<fresh_index>, C<fresh_immutable>,
C<fresh_default>: how long the cache uses a copy of each kind before it asks
upstream again.  See L</Four kinds of URL, and one it does not keep>.  The
values use the units of nginx, for example C<10m>, C<1h> and C<365d>.

=item * C<ipv6>: listen on IPv6 as well as IPv4.  True by default.

=back

=cut

sub args {
    my $duration = '\A\d+(?:ms|[smhdwMy])?\z';
    return (
        type       => 'object',
        properties => {

            # The defaults are on the members and not on the map, so that an
            # operator who adds one host keeps all of the defaults.
            upstreams => {
                type    => 'object',
                default => {},

                # The hosts that every recipe names by default, and the hosts that
                # the configured domains reach.  A koan pointed at its own gitea is
                # a host that the class alone does not name.
                properties           => { map { $_ => { type => 'boolean', default => 1 } } List::Util::uniq( sort Provisioner::Cookbook->fetch_hosts, Provisioner::Cookbook->configured_fetch_hosts ) },
                additionalProperties => { type => 'boolean' },
                description          => 'Hosts the cache fetches from, each true or false.  The defaults are every host that a recipe names in fetch_hosts.  Name another host to add it.  Set a default host to false to remove it.',
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
                description => 'The most disk space that copies can use, in GB.  nginx enforces this limit lazily, so the store can go over it for a short time.',
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
                description => 'How long a copy that nobody asks for is kept.  The default is a hundred years, so that only a full disk removes a copy.  A copy that nobody asked for in a year can be a pinned version that upstream no longer has.',
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
                description => 'How long an index is used before upstream is asked again.  An index is a file that says which version is current.',
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

Returns the kinds of URL, most specific first.  Each is a hash of three keys:

=over 4

=item * C<name>: C<aptindex>, C<index>, C<immutable> or C<default>.  See
L</Four kinds of URL, and one it does not keep>.

=item * C<fresh>: the C<args> key that sets how long a copy of that kind stays
fresh.

=item * C<pattern>: a regex that is matched against C<HOST/PATH>.  C<default>
has none, because it takes every URL that the others do not take.

=back

C<aptindex> also has C<no_stale>, which is true.  A kind that no recipe declares
a pattern for is left out.

This module does not hold the patterns.  Each recipe declares its own in
C<cache_classes>, see L<Provisioner::Recipe>.  This method returns the union of
them.  Thus a recipe that gets a new upstream does not need an edit to the
cache.  This module holds only C<default>, which belongs to no recipe, and
C<$PASSTHROUGH>.

=cut

our @CLASS_ORDER = (

    # First, and the only kind that is never served stale: an apt index is half
    # of a pair, and a pair from two moments is a hash-sum mismatch.
    { name => 'aptindex',  fresh => 'fresh_apt_index', no_stale => 1 },
    { name => 'index',     fresh => 'fresh_index' },
    { name => 'immutable', fresh => 'fresh_immutable' },
);

sub classes {
    my ($self) = @_;

    my %pattern;
    push( @{ $pattern{ $_->{class} } }, $_->{pattern} ) for Provisioner::Cookbook->cache_classes;

    # Sorted and unique, so that the rendered vhost does not change with the
    # order in which the recipes load.
    my @classes = map {
        my @patterns = List::Util::uniq( sort @{ $pattern{ $_->{name} } // [] } );
        @patterns ? { %$_, pattern => join( '|', @patterns ) } : ();
    } @CLASS_ORDER;

    return ( @classes, { name => 'default', fresh => 'fresh_default' } );
}

=head2 $PASSTHROUGH

The pattern of the URLs that the cache never keeps: the smart-HTTP ref
advertisement of git.  It is matched in the same way as the classes, and before
them.

=cut

our $PASSTHROUGH = '[^/]+/.+/info/refs\?service=git-';

=head2 %required = $recipe->required_recipes()

Returns C<nginx>, which fetches and serves.  C<nginx> brings C<ufw>, with the
rate limit of nginx on 443.  The nginx profile that ufw allows also lets the
cache connect to 443 upstream.

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

Writes the vhost and the certificate that it presents, see C<certify>.  Returns
the names of the files that it wrote.

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

Adds these keys to C<%opts> and returns it:

=over 4

=item * C<allow>: the hosts in C<upstreams> that are true, sorted.

=item * C<allow_re>: the same hosts, as a regex alternation.

=item * C<classes>: the result of C<classes>, with each C<fresh> replaced by the
duration configured for it.

=item * C<passthrough>: C<$PASSTHROUGH>, for the template.

=back

It also replaces C<resolvers> with the resolvers of the fleet, less every
loopback and IPv6 address.  nginx looks an upstream up when it fetches, so it
needs servers that it can reach.

Dies if no host in C<upstreams> is true, because that cache fetches nothing.
Dies if a host is not a plain DNS name, because the vhost uses it in a regex and
the certificate names it.  Dies if no resolvers are left.

Loopback is correct on a guest that runs the pdns recursor, and nothing listens
there on this guest.  nginx rotates through its resolvers, so a loopback
resolver refuses some of the lookups.  C<bin/new_config> refuses an installation
that names loopback, and C<nostubresolver> puts it first on the guest that needs
it.  This strips loopback from a list that was written elsewhere.  For example,
a runner writes its own, and L<Provisioner::Recipe::trogrunner> defaults its
resolvers to C<1.1.1.1> and C<8.8.8.8>.

The stub of systemd-resolved fails over correctly, but this does not use it,
because the C<nostubresolver> recipe turns it off on these guests.  IPv6 goes
because nginx is told C<ipv6=off>, as apt is told to use IPv4.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @allow = sort grep { $opts{upstreams}{$_} } keys %{ $opts{upstreams} };
    die "fetchcache has no upstreams turned on, so it would fetch nothing.\n" unless @allow;

    # is_domain also checks the top-level domain, so it refuses a host under a
    # made-up TLD.
    my @bad = grep { !Data::Validate::Domain::is_domain($_) } @allow;
    die "fetchcache upstreams must be plain host names; these are not: @bad\n" if @bad;

    $opts{allow}       = \@allow;
    $opts{allow_re}    = join( '|', map { quotemeta } @allow );
    $opts{passthrough} = $PASSTHROUGH;
    $opts{classes}     = [
        map {
            { %$_, fresh => $opts{ $_->{fresh} } }    ## no critic (ValuesAndExpressions::ProhibitCommaSeparatedStatements) -- an anonymous hash, which PPI reads as a block
        } $self->classes
    ];

    my @given = @{ Provisioner::Utils::coerce_arrayref( $opts{resolvers} ) };
    $opts{resolvers} = [ grep { !m/\A127\./ && index( $_, ':' ) < 0 } @given ];
    die "fetchcache needs resolvers it can reach to look its upstreams up with, and of '@given' none are left once loopback and IPv6 are taken out.\n"
      unless @{ $opts{resolvers} };

    return %opts;
}

=head2 $paths = Provisioner::Recipe::fetchcache->authority()

Returns the authority that signs the certificate of the cache, as a hash
reference of C<cert> and C<key>, the paths of the two files.  If the files are
not there, it makes them first.  See L</The certificate, and who signs it>.

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

    # The key first, because the pair counts as made only when both files exist.
    Provisioner::Utils::write_pem( $paths{key},  IO::Socket::SSL::Utils::PEM_key2string($key),   0600 );
    Provisioner::Utils::write_pem( $paths{cert}, IO::Socket::SSL::Utils::PEM_cert2string($cert), 0644 );

    IO::Socket::SSL::Utils::CERT_free($cert);
    IO::Socket::SSL::Utils::KEY_free($key);

    return \%paths;
}

=head2 @written = $recipe->certify($output_dir, @hosts)

Signs a certificate that names C<@hosts> with the C<authority>.  Writes it into
C<$output_dir> as F<fetchcache.crt>, followed by the certificate of the
authority, and writes its key as F<fetchcache.key>.  Returns the names of the
two files.

It signs a new certificate at each call.  The certificate is good for 397 days,
which is the longest that clients accept.

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

    Provisioner::Utils::write_pem( "$output_dir/fetchcache.key", IO::Socket::SSL::Utils::PEM_key2string($key),                                                    0600 );
    Provisioner::Utils::write_pem( "$output_dir/fetchcache.crt", IO::Socket::SSL::Utils::PEM_cert2string($cert) . File::Slurper::read_text( $authority->{cert} ), 0644 );
    ## use critic

    IO::Socket::SSL::Utils::CERT_free($_) for $cert, $ca_cert;
    IO::Socket::SSL::Utils::KEY_free($_)  for $key,  $ca_key;

    return qw{fetchcache.crt fetchcache.key};
}

1;
