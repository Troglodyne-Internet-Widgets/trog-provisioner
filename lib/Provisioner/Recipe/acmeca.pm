package Provisioner::Recipe::acmeca;

#ABSTRACT: An ACME certificate authority on the guest, so a name no public CA will validate still gets a real certificate.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

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

An ACME server on the guest.  It issues from the same authority that signs the
certificate of the fetch cache.  See L<Provisioner::Recipe::fetchcache/authority>.

A public CA cannot issue a certificate for a name under a reserved TLD.  Nothing
outside this fleet can resolve the name, so the CA cannot validate a challenge
for it.  dehydrated then fails and the makefile is red.  The guest still works
on the self-signed pair that the C<ssl> target makes.  But nothing runs the path
that issues a real certificate.

This recipe is the other end of that path.  dehydrated, its hook, lexicon and
the C<_acme-challenge> record do not change.  Only the CA that dehydrated asks
is different.  So the real client runs the real path, on the guest.

=head2 Why it runs here, on the guest

The guest is already authoritative for its own name.
L<Provisioner::Recipe::pdns> runs an authoritative server on C<127.0.0.1:2500>.
It also runs a recursor on C<:53>, which forwards this domain to that server.
The C<dns_preference> of letsencrypt resolves to that server, and points lexicon
at its API socket.  So the guest writes, serves and reads the record without a
packet that leaves the machine.  A CA on the same machine can then validate the
record with no view of the fleet.

A CA on another host cannot.  step-ca resolves a C<dns-01> challenge through
the resolver of its own host, and nothing off this guest can answer for its
zone.

The CA listens on loopback only.  Its only client is the dehydrated of this
guest.  So there is no port to open and no rate limit to set.

=head2 One CA for the guest, not one for each domain

step-ca is a single service with one database, one listener and one
intermediate.  So this recipe belongs to the guest and not to the domain.  Its
fragment is the global half.  The guest installs, configures and starts it
once, for any number of domains.

Nothing addresses this CA by the name of a domain.  dehydrated asks
C<https://localhost:port/acme/trog/directory>, and the listener is bound to
loopback.  So C<ca.json> names C<localhost> and nothing else.  This matters
because step-ca crash-loops on a name outside the constraint below.  The name of
a second domain under a different top-level domain is such a name.

C<constrain_to> still follows the first domain that the guest builds.  So it
sets what this CA can issue for at all.  Usually the domains of a guest share a
top-level domain, and under a reserved TLD they always do.  Then nothing needs
to change.  If a guest mixes top-level domains, it must set C<constrain_to>
itself.  The constraint is a list, and one intermediate can carry several.

=head2 The intermediate, and what stops it signing the internet

The private key of the authority stays on the provisioner, as it does for the
fetch cache.  step-ca never sees it.  step-ca gets an intermediate and the root
to chain to.  This recipe makes the intermediate at C<generate_files> time and
ships it in the payload.  step-ca documents this arrangement and does not need
the root signing key.  So this is the same authority, and not a second one that
nothing trusts.

That has a consequence, and it is the reason C<constrain_to> exists.  The
authority has no name constraints of its own and vouches for any name.  Every
guest that provisions through the fetch cache installs its certificate into the
trust store.  So an intermediate key on a throwaway guest can mint a trusted
certificate for the domain of anybody.

So the intermediate carries a name constraint that permits only
C<constrain_to>.  If the guest issues for any other name, the client that checks
the chain refuses it.  Everything that the intermediate signs inherits the
constraint, so the constraint is sufficient on its own.

The constraint also permits C<localhost>, and this is not a loophole.  When
step-ca starts, it issues its own listener certificate from this intermediate,
for the names in C<ca.json>.  If the constraint forbids one of them, step-ca
does not start.  It crash-loops on
C<DNS name "localhost" is not permitted by any constraint>.  So the name that
the CA answers to must be inside the constraint.  The result is a certificate
for C<localhost> that the fleet authority signed.  It is worth exactly as much as
the loopback interface that it names.

=cut

# The release that the fragment downloads.  It must be a published release,
# because any other version is a 404 on the guest in the middle of a provision.
our $STEP_CA_VERSION = '0.30.2';

our $DEFAULT_PORT = 9000;

# Five years.  This is shorter than the ten years of the authority, so it
# expires before its signer.  It is far longer than any guest lives.
our $INTERMEDIATE_DAYS = 1825;
my $DAY = 86_400;

=head2 @ports = $recipe->listens(%opts)

step-ca on C<port>, on loopback.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes calls this
    # before validation.
    return ( $opts{port} // $DEFAULT_PORT );
}

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

Sets C<constrain_to> to the top-level domain of C<$opts{domain}>, unless the
domain already names one.  A CA on a guest issues that guest its certificate.
So the top-level domain of the guest is the only one it vouches for.

A schema default cannot depend on another field, so this happens here and not
in C<args>.

Dies if C<constrain_to> is not set and C<domain> has no top-level domain.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{constrain_to} //= Provisioner::Utils::tld_of( $opts{domain} );
    die "acmeca could not tell what top-level domain to constrain itself to from '" . ( $opts{domain} // q{} ) . "'; set constrain_to for this domain\n"
      unless $opts{constrain_to};

    return %opts;
}

=head2 %required = $recipe->required_recipes(%opts)

Requires the DNS server on this guest, which answers the challenge that this CA
sets.  The name comes from L<Provisioner::DNSRecipe/local_implementation>.  The
interface decides what serves a zone.  This recipe only says that a registrar
cannot do it, because step-ca validates through the resolver of its own host.

It hands that recipe nothing.  The DNS recipe makes its own API key when the
operator sets none.

It does B<not> require letsencrypt.  The edge points the other way: a domain
that points dehydrated at this CA needs the CA first.

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

Writes the configuration and the unit, and then the key material that the CA
issues from.  See C<intermediate>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated(%vars);

    return ( @written, $self->intermediate( $output_dir, $opts{constrain_to} ) );
}

=head2 @written = $recipe->intermediate($output_dir, $tld)

Signs an intermediate with the authority of the fetch cache, constrained to
names under C<$tld> and C<localhost>.  Writes it into C<$output_dir> as
F<acmeca-intermediate.crt>, and its key as F<acmeca-intermediate.key>.  Also
writes the authority as F<acmeca-root.crt>, which the guest chains to and
trusts.  Returns those three file names.

The first of the two recipes to ask makes the authority, and both keep it.  So a
fleet with a cache and a CA has one root.  Only the certificate of the root
travels.  Its key stays where it was made.

Dies if it cannot copy the certificate of the authority.

=cut

sub intermediate {
    my ( $self, $output_dir, $tld ) = @_;

    my $authority = Provisioner::Cookbook->load('fetchcache')->authority();
    my $ca_cert   = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $ca_key    = IO::Socket::SSL::Utils::PEM_file2key( $authority->{key} );

    my ( $cert, $key ) = IO::Socket::SSL::Utils::CERT_create(

        # CA sets basicConstraints and the key usage that step-ca signs with.
        # The name constraint goes in ext, because no argument sets one.  Do not
        # add basicConstraints to ext, because CA already gives it to OpenSSL.
        CA        => 1,
        subject   => { commonName => "trog-provisioner acme intermediate for .$tld" },
        issuer    => [ $ca_cert, $ca_key ],
        not_after => time + $INTERMEDIATE_DAYS * $DAY,
        key       => IO::Socket::SSL::Utils::KEY_create_ec('prime256v1'),
        ext       => [ { sn => 'nameConstraints', data => "critical,permitted;DNS:.$tld,permitted;DNS:localhost" } ],
    );

    Provisioner::Utils::write_pem( "$output_dir/acmeca-intermediate.key", IO::Socket::SSL::Utils::PEM_key2string($key),   0600 );
    Provisioner::Utils::write_pem( "$output_dir/acmeca-intermediate.crt", IO::Socket::SSL::Utils::PEM_cert2string($cert), 0644 );

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
