package Provisioner::Recipe::acmeca;

#ABSTRACT: An ACME certificate authority on the guest, so a name no public CA will validate still gets a real certificate.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use File::Copy();
use IO::Socket::SSL::Utils();

use Provisioner::Cookbook();
use Provisioner::DNSRecipe();
use Provisioner::Utils();

=head1 Provisioner::Recipe::acmeca

=head2 SYNOPSIS

    somedomain:
        acmeca:
        letsencrypt:
            ca: https://localhost:9000/acme/trog/directory
            dns_preference: pdns
        pdns:
            api_key: secret:group/entry/field

=head2 DESCRIPTION

An ACME server on the guest, issuing from the same authority the fetch cache
signs with -- see L<Provisioner::Recipe::fetchcache/authority>.

A guest named under a reserved TLD cannot be issued a certificate by a public
CA: nothing outside this fleet can resolve the name, so no challenge it sets can
be validated, and every provision of one ends with dehydrated failing and the
makefile red.  The guest is left working, on the self-signed pair the C<ssl>
target makes, but the path that would have issued it a real certificate is never
exercised by anything.

This is the other end of that path.  dehydrated, its hook, lexicon and the
C<_acme-challenge> record are all unchanged; only the CA it asks is different.
What was untested is then tested, on the guest, with the real client.

=head2 Why it runs here, on the guest

Because the guest is already authoritative for its own name.
L<Provisioner::Recipe::pdns> runs an authoritative server on C<127.0.0.1:2500>
and a recursor on C<:53> which forwards this domain to it, and letsencrypt's
C<dns_preference> resolves to that server, pointing lexicon at its API socket.
So the record is written, served and read without a packet leaving the machine,
and a CA in the same place needs no view of the fleet to validate anything.

A CA elsewhere would need one: step-ca resolves a C<dns-01> challenge through
its own host's resolver, and nothing outside this guest can answer for its zone.

It listens on loopback alone.  The only client is this guest's own dehydrated,
so there is no port to open and no rate limit to set.

=head2 One CA for the guest, not one for each domain

step-ca is a single service with one database, one listener and one
intermediate, so this recipe is the guest's rather than the domain's and its
fragment is the global half: installed, configured and started once however many
domains the guest ends up holding.

Nothing addresses this CA by the name of a domain.  dehydrated is pointed at
C<https://localhost:port/acme/trog/directory> and the listener is bound to
loopback, so C<ca.json> names C<localhost> and nothing else -- which also
retires a way for it to refuse to start, since a name outside the constraint
below crash-loops step-ca and a second domain's name is exactly that whenever
the two are under different top-level domains.

What does still follow the first domain built is C<constrain_to>, and therefore
what this CA may issue for at all.  A guest whose domains share a top-level
domain -- which is the ordinary case, and every case under a reserved one --
wants nothing done about that.  A guest mixing them has to say C<constrain_to>
for itself; the constraint is a list, and one intermediate can carry several.

=head2 The intermediate, and what stops it signing the internet

The authority's private key stays on the provisioner, as it does for the fetch
cache: step-ca never sees it.  What it gets is an intermediate, minted here at
C<generate_files> time and shipped in the payload, and the root to chain to.
That is step-ca's documented arrangement -- it does not need the root signing
key -- and it is what lets this be the same authority rather than a second one
nothing trusts.

The consequence has to be stated plainly, because it is the reason
C<constrain_to> exists.  That authority carries no name constraints of its own
and vouches for any name at all, and its certificate is installed into the trust
store of every guest that provisions through the fetch cache.  An intermediate
key shipped to a throwaway guest is therefore a key that could mint a trusted
certificate for anybody's domain, on a machine built to be thrown away.

So the intermediate is issued with a name constraint permitting only
C<constrain_to>, and a guest that tried to issue for anything else would be
refused by the client checking the chain rather than trusted.  The constraint is
inherited by anything the intermediate goes on to sign, which is what makes it
sufficient on its own.

C<localhost> is permitted alongside it, and that is not a loophole being left
open.  step-ca issues its own listener certificate from this intermediate when
it starts, for the names in C<ca.json>, and refuses to start at all if the
constraint forbids one of them -- measured on a guest, where it crash-looped on
C<DNS name "localhost" is not permitted by any constraint>.  The name the CA
answers to therefore has to be inside the constraint.  What that grants is a
certificate for C<localhost> signed by the fleet authority, which is worth
exactly as much as the loopback interface it names.

=cut

# The release the fragment downloads.  It has to be one that was actually
# published: a version that was not is a 404 on the guest partway through a
# provision rather than an older step-ca.
our $STEP_CA_VERSION = '0.30.2';

our $DEFAULT_PORT = 9000;

## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
# Five years.  Shorter than the authority's ten, so it expires before what
# signed it, and far longer than the guests it serves ever live.
our $INTERMEDIATE_DAYS = 1825;
my $DAY = 86_400;
## use critic

=head2 %schema = $recipe->args()

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            steppath => {
                type        => 'string',
                pattern     => q{\A/[^\0]*[^/\0]\z},
                default     => '/etc/step-ca',
                description => "Where step-ca keeps its certificates, its key and its database.  The fragment, the unit and ca.json are all written from this one value, so they cannot disagree about where the CA lives.",
            },
            port => {
                type        => 'integer',
                minimum     => 1024,
                maximum     => 65_535,
                default     => $DEFAULT_PORT,
                description => 'The port step-ca answers on, bound to 127.0.0.1.  Nothing off the guest talks to it, so this is only a matter of what else is listening.',
            },
            version => {
                type        => 'string',
                pattern     => q{\A\d+[.]\d+[.]\d+\z},
                default     => $STEP_CA_VERSION,
                description => 'The step-ca release to install.  Pinned rather than tracked: see MAINTENANCE.md.',
            },
            constrain_to => {
                type        => 'string',
                pattern     => q{\A[a-z\d]([a-z\d-]*[a-z\d])?\z},
                description => "The one top-level domain this CA is allowed to issue for, written into the intermediate as a name constraint.  It is what stops a key shipped to a throwaway guest from being trusted for anybody else: see perldoc Provisioner::Recipe::acmeca.  Defaults to the top-level domain of the guest this CA is built for, which is the only name it has any business issuing.",
            },
            default_duration => {
                type        => 'string',
                pattern     => q{\A\d+h\z},
                default     => '24h',
                description => 'How long a certificate this CA issues is good for when the client asks for no particular lifetime.',
            },
            max_duration => {
                type        => 'string',
                pattern     => q{\A\d+h\z},
                default     => '2160h',
                description => 'The longest lifetime this CA will issue, whatever the client asks for.  Ninety days by default, which is what the public CA this stands in for allows.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

C<constrain_to> comes from the guest this CA is built for.  A CA on a guest
exists to issue that guest its certificate, and the guest's own top-level domain
is therefore the only one it has any business vouching for -- so the constraint
follows the domain rather than a fixed default that is right for C<.test> and
wrong for every other reserved TLD.

Derived here rather than declared in the schema because a schema default cannot
depend on another field.  A domain naming C<constrain_to> explicitly keeps what
it named.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{constrain_to} //= Provisioner::Utils::tld_of( $opts{domain} );
    die "acmeca could not tell what top-level domain to constrain itself to from '" . ( $opts{domain} // q{} ) . "'; set constrain_to for this domain\n"
      unless defined $opts{constrain_to} && length $opts{constrain_to};

    return %opts;
}

=head2 %required = $recipe->required_recipes(%opts)

The DNS server on this guest, which is what answers the challenge this CA sets.
Named through L<Provisioner::DNSRecipe/local_implementation> rather than
literally: what serves a zone is the interface's business, and this recipe only
needs to say that a registrar will not do -- step-ca validates through the
host's own resolver, so the record has to be one the guest itself serves.

Nothing is handed to it: its API key is the operator's to supply, and a guest
that names this recipe without configuring one should be told so rather than
issued a key nobody chose.

letsencrypt is B<not> required here, and the edge points the other way: a domain
can stand up a CA without asking anything of it, while a domain pointing
dehydrated at one needs it to exist first.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    return ( Provisioner::DNSRecipe->local_implementation() => sub { return () }, $self->SUPER::required_recipes(%opts) );
}

=head2 @hosts = $recipe->fetch_hosts()

=cut

sub fetch_hosts {
    my ($self) = @_;

    return $self->github_release_hosts();
}

=head2 %files = $recipe->template_files()

=cut

sub template_files {
    return (
        'acmeca.ca.json.tt' => 'acmeca.ca.json',
        'acmeca.service.tt' => 'acmeca.service',
    );
}

=head2 @written = $recipe->generate_files($output_dir, %vars)

The configuration and the unit, and then the key material the CA issues from:
see C<intermediate>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated(%vars);

    return ( @written, $self->intermediate( $output_dir, $opts{constrain_to} ) );
}

=head2 @written = $recipe->intermediate($output_dir, $tld)

Sign an intermediate with the fetch cache's authority, constrained to names
under C<$tld>, and write it into C<$output_dir> as F<acmeca-intermediate.crt>
with its key as F<acmeca-intermediate.key> -- plus the authority itself as
F<acmeca-root.crt>, which the guest needs to chain to and to trust.

The authority is made by whichever of the two recipes asks for it first and kept
thereafter, so a fleet that runs both a cache and a CA has one root and not two.

The root travels as a certificate only.  Its key stays where it was made.

=cut

sub intermediate {
    my ( $self, $output_dir, $tld ) = @_;

    my $authority = Provisioner::Cookbook->load('fetchcache')->authority();
    my $ca_cert   = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $ca_key    = IO::Socket::SSL::Utils::PEM_file2key( $authority->{key} );

    my ( $cert, $key ) = IO::Socket::SSL::Utils::CERT_create(

        # CA sets basicConstraints and the key usage that lets step-ca sign with
        # this; the constraint is the extension, because there is no argument
        # for one.  Naming basicConstraints here as well would be a second copy
        # of an extension OpenSSL has already been given.
        CA        => 1,
        subject   => { commonName => "trog-provisioner acme intermediate for .$tld" },
        issuer    => [ $ca_cert, $ca_key ],
        not_after => time + $INTERMEDIATE_DAYS * $DAY,
        key       => IO::Socket::SSL::Utils::KEY_create_ec('prime256v1'),
        ext       => [ { sn => 'nameConstraints', data => "critical,permitted;DNS:.$tld,permitted;DNS:localhost" } ],
    );

    ## no critic (Plicease::ProhibitLeadingZeros) -- file modes, which are octal
    Provisioner::Utils::write_pem( "$output_dir/acmeca-intermediate.key", IO::Socket::SSL::Utils::PEM_key2string($key),   0600 );
    Provisioner::Utils::write_pem( "$output_dir/acmeca-intermediate.crt", IO::Socket::SSL::Utils::PEM_cert2string($cert), 0644 );
    ## use critic

    IO::Socket::SSL::Utils::CERT_free($_) for $cert, $ca_cert;
    IO::Socket::SSL::Utils::KEY_free($_)  for $key,  $ca_key;

    File::Copy::copy( $authority->{cert}, "$output_dir/acmeca-root.crt" )
      or die "Could not give the guest the authority to chain to: $!\n";

    return qw{acmeca-root.crt acmeca-intermediate.crt acmeca-intermediate.key};
}

=head2 @tests = $recipe->tests()

=cut

sub tests {
    return qw{acmeca.tt};
}

1;
