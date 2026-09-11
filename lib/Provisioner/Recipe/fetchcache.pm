package Provisioner::Recipe::fetchcache;

#ABSTRACT: Keep what the fleet downloads, and hand it out again when upstream will not.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Provisioner::Utils();

=head1 NAME

Provisioner::Recipe::fetchcache - a pull-through cache for the tarballs, scripts
and indices recipes download, so an upstream outage stops being a failed build.

=head1 SYNOPSIS

    fetchcache.example.com:
        fetchcache: {}

and then point the fleet at it:

    _base:
        _global:
            cache: fetchcache.example.com

=head1 DESCRIPTION

An nginx that fetches from a fixed list of upstreams on a guest's behalf and
keeps what it fetched.  C<https://HOST/PATH> is served as
C<http://E<lt>cacheE<gt>/HOST/PATH>:

    curl http://fetchcache.example.com/www.cpan.org/modules/02packages.details.txt.gz

What a guest does with that is L<Provisioner::DistroRecipe>'s C<cache> and
F<scripts/fetch>, which is the other half and is configured separately.

=head2 Pull-through, and stale rather than failing

Nothing is fetched until a guest asks for it, and what has been fetched is kept
for C<inactive> after it was last asked for.  When upstream fails -- an error, a
timeout, or a 403, 404, 429 or 5xx -- a copy the cache already has is served
instead, however old.  That is the point of it: GitHub answering 503 for an hour
is an hour of builds that did not notice.

A 404 is on that list on purpose.  CPAN moves superseded releases off to BackPAN
and a project can delete a release, and a pinned build still wants the version
it was pinned to.  The cache keeps every version it has ever handed out.

=head2 Three kinds of URL

How long a copy is used before upstream is asked again depends on what the URL
is, which the recipe knows from its shape -- see C<@CLASSES>:

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

=head2 Redirects are followed here

A GitHub release asset is a redirect to a signed URL on another host that stops
working within minutes, so a guest handed the redirect would cache nothing
useful.  The cache follows it instead, and keeps the body under the URL the guest
asked for.  It follows only to a host in C<upstreams>, and only over https;
anything else is a C<502>.

=head2 What a guest has to trust

Guests reach the cache over plain HTTP, the same as the package mirror, so the
cache is a trust point: what it serves is what gets built.  What keeps that
narrow is that it only fetches from C<upstreams>, over TLS it verifies against
the system's certificate authorities, and never forwards a guest's
C<Authorization> or C<Cookie> -- so nothing it keeps was fetched as anybody in
particular.

=head2 It wants a guest of its own

For the reasons L<Provisioner::Recipe::aptmirror> gives: its vhost answers for
the guest's address, so it takes requests that would otherwise go unmatched,
and it sets C<backlog> on port 80, which nginx refuses to see set twice.

=head2 Seeing what it did

Every response carries C<X-Cache-Status> -- C<MISS>, C<HIT>, C<STALE>,
C<UPDATING>, C<EXPIRED>, C<REVALIDATED> -- and F</var/log/nginx/fetchcache.log>
records the same for every request.  C<http://E<lt>cacheE<gt>/fetchcache-status>
answers C<ok> for anything that wants to know whether the cache is there.

=head2 What is deliberately not here

B<No C<remote_files>, no C<restores>, no C<datadirs>>, and the store is outside
C<install_dir>, for the reason L<Provisioner::Recipe::aptmirror> gives: it is
re-fetchable by definition, and the C<data> target walks C<install_dir>
recursively on every provision.

Nothing requires it.  A fleet with no cache configured downloads straight from
upstream, as it always has.

=head1 METHODS

=head2 %args = $recipe->args()

=over 4

=item * C<upstreams> -- the hosts it will fetch from, each true or false.  The
defaults are the ones recipes here download from, each on by default; naming
another adds it, and naming one of the defaults false turns it off.

=item * C<store>, C<max_size_gb>, C<inactive> -- where copies are kept, how much
of the disk they may take, and how long one nobody asks for survives.

=item * C<fresh_index>, C<fresh_immutable>, C<fresh_default> -- how long a copy
of each kind is used before upstream is asked again.  In nginx's units:
C<10m>, C<1h>, C<365d>.

=back

=cut

# The hosts recipes here download from.  On the members rather than on the map,
# so that an operator adding one host keeps all of these.
my @DEFAULT_UPSTREAMS = qw{
  www.cpan.org
  cpan.metacpan.org
  fastapi.metacpan.org
  github.com
  codeload.github.com
  release-assets.githubusercontent.com
  objects.githubusercontent.com
  raw.githubusercontent.com
  api.github.com
  garagehq.deuxfleurs.fr
  download.imagemagick.org
};

sub args {
    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
    my $duration = '\A\d+(?:ms|[smhdwMy])?\z';
    return (
        type       => 'object',
        properties => {
            upstreams => {
                type                 => 'object',
                default              => {},
                properties           => { map { $_ => { type => 'boolean', default => 1 } } @DEFAULT_UPSTREAMS },
                additionalProperties => { type => 'boolean' },
                description          => 'Hosts the cache will fetch from, each true or false.  The defaults are every host a recipe here downloads from; naming another adds it, and naming a default false removes it.',
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
            inactive => {
                type        => 'string',
                default     => '365d',
                pattern     => $duration,
                description => 'How long a copy nobody asks for is kept, however fresh it is.',
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
            backlog => {
                type        => 'integer',
                default     => 32768,
                minimum     => 0,
                description => 'listen() backlog for the vhost.',
            },
        },
    );
}

=head2 @CLASSES

The three kinds of URL, most specific first, as C<name>, the C<args> key saying
how fresh a copy stays, and C<shape> -- a regex matched against the path after
the leading slash, so against C<HOST/PATH>.  C<default> has no shape and takes
whatever the other two did not.

These are facts about how the upstreams lay out their URLs rather than
configuration, which is why they are here and not in C<args>.

=cut

our @CLASSES = (
    {
        name  => 'index',
        fresh => 'fresh_index',
        shape => join(
            '|', qw{
              (?:api\.github\.com|fastapi\.metacpan\.org)/
              [^/]+/modules/
              [^/]+/[^/]+/[^/]+/releases/latest(?:/|$)
            }
        ),
    },
    {
        name  => 'immutable',
        fresh => 'fresh_immutable',
        shape => join(
            '|', qw{
              [^/]+/authors/id/(?!.*/CHECKSUMS$)
              [^/]+/[^/]+/[^/]+/releases/download/
              [^/]+/[^/]+/[^/]+/archive/(?:[0-9a-f]{40}|refs/tags/)
              codeload\.github\.com/[^/]+/[^/]+/[^/]+/[0-9a-f]{40}$
              garagehq\.deuxfleurs\.fr/_releases/
              download\.imagemagick\.org/archive/releases/
            }
        ),
    },
    { name => 'default', fresh => 'fresh_default' },
);

=head2 %required = $recipe->required_recipes()

C<nginx>, which is what fetches and serves.  C<ufw> arrives behind it, and the
nginx profile it allows out is what lets the cache reach 443 upstream.

=cut

sub required_recipes {
    return ( nginx => sub { return () } );
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return ( 'fetchcache.nginx.conf.tt' => 'fetchcache.nginx.conf' );
}

=head2 @tests = $recipe->tests()

=cut

sub tests { return ('fetchcache.tt') }

=head2 %opts = $recipe->enrich(%opts)

Turns C<upstreams> into C<allow>, the hosts that are on, and C<allow_re>, the
same as a regex alternation; and C<@CLASSES> into C<classes>, each with the
freshness configured for it.

Dies on a host that is not a plain DNS name, because it is written into the
vhost as a regex, and on an empty list, which would be a cache that fetches
nothing.  Dies without C<resolvers> too: nginx looks an upstream up when it
fetches, and C<bin/new_config> always supplies them.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @allow = sort grep { $opts{upstreams}{$_} } keys %{ $opts{upstreams} };
    die "fetchcache has no upstreams turned on, so it would fetch nothing.\n" unless @allow;

    my @bad = grep { !m/\A(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+[a-z\d](?:[a-z\d-]*[a-z\d])?\z/i } @allow;
    die "fetchcache upstreams must be plain host names; these are not: @bad\n" if @bad;

    $opts{allow}    = \@allow;
    $opts{allow_re} = join( '|', map { quotemeta } @allow );
    $opts{classes}  = [
        map {
            { %$_, fresh => $opts{ $_->{fresh} } }
        } @CLASSES
    ];

    $opts{resolvers} = Provisioner::Utils::coerce_arrayref( $opts{resolvers} );
    die "fetchcache needs resolvers to look its upstreams up with, and was given none.\n" unless @{ $opts{resolvers} };

    return %opts;
}

1;
