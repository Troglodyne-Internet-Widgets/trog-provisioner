package Provisioner::Recipe::acmeca;

#ABSTRACT: An ACME certificate authority on the guest, so a name no public CA will validate still gets a real certificate.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Copy();
use Readonly;
use IO::Socket::SSL::Utils();

use Time::HiRes qw{time};
use Provisioner::Cookbook();
use Provisioner::Vars();
use Provisioner::Utils();
use Trog::Utils();
use Trog::Config();
use Trog::Patterns();

=head1 Provisioner::Recipe::acmeca

=head2 SYNOPSIS

    somedomain:
        acmeca:
        letsencrypt:
            ca: https://localhost:9000/acme/trog/directory
        pdns:

=head2 DESCRIPTION

An ACME server on the guest.  It issues from the same authority that signs the
certificate of the fetch cache, where this installation holds the key of that
authority.  See L<Provisioner::Recipe::fetchcache/authority>, and
C<issuing_authority> below for an installation that holds only its
certificate.

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
L<Provisioner::Recipe::registrar> says that this server holds the zone, and
points lexicon at its API socket.  So the guest writes, serves and reads the record without a
packet that leaves the machine.  A CA on the same machine can then validate the
record with no view of the fleet.

A CA on another host cannot, unless that host holds the zone.  step-ca
resolves a C<dns-01> challenge through the resolver of its own host, and
nothing off this guest can answer for its zone.

=head2 Or on the authority, for the guests that name it

A guest whose C<registrar> names an C<authority> has no zone of its own to
serve.  The authority holds it, and lexicon writes the record there.  See
L<Provisioner::Recipe::registrar>.  The authority runs pdns, so it runs this
CA for its own names, and its resolver answers for every zone that it holds.
So the CA of the authority can validate the challenge of the guest.

Such a guest asks the CA of its authority, and runs none of its own, where the
authority is under the same reserved TLD.  See C<fleet_ca_of>.  So one
intermediate key serves every guest under an authority, in place of one key on
each of them.  The guest already trusts the fleet authority, because its
registrar installs it for the API of the authority.

The CA listens on loopback only.  On a guest that runs pdns, the vhost of the
API of pdns passes C</acme/> to it, behind the same allow list as the API.  See
L<Provisioner::Recipe::pdns/The API proxy>.  So there is no port to open and no
rate limit to set.  Anybody that the vhost lets in can open an account, and a
certificate still needs a record in the zone, which only the token of that zone
can write.

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

=head1 METHODS

=cut

# The release that the fragment downloads.  It must be a published release,
# because any other version is a 404 on the guest in the middle of a provision.
our $STEP_CA_VERSION = '0.30.2';

our $DEFAULT_PORT = 9000;

# Five years.  This is shorter than the ten years of the authority, so it
# expires before its signer.  It is far longer than any guest lives.
our $INTERMEDIATE_DAYS = 1825;

=head2 $recipe->listens(%opts)

step-ca on C<port>, on 127.0.0.1.  C<%opts> are the options of the recipe,
which can be unvalidated, so an absent C<port> means the default, 9000.

Returns a list of one address and port, as C<127.0.0.1:9000>.

    my @claims = $recipe->listens( port => 9000 );

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes calls this
    # before validation.
    return ( "127.0.0.1:" . ( $opts{port} // $DEFAULT_PORT ) );
}

=head2 $recipe->args()

The schema of the options: C<steppath>, C<port>, C<version>,
C<constrain_to>, C<default_duration> and C<max_duration>, each with the
description that C<bin/recipes acmeca> prints.

Returns the schema as a list of pairs, for L<Provisioner::Recipe/args>.

    my %schema = $recipe->args();

=cut

# An absolute path that does not end in a slash.
my $ABSOLUTE_PATH = qr/\A \/ [^\0]* [^\/\0] \z/;

# One label of a host name, in lower case, which starts and ends with a letter
# or a digit.
my $LABEL_END = qr/[[:lower:][:digit:]]/;
my $LABEL     = qr/\A $LABEL_END (?: [[:lower:][:digit:]-]* $LABEL_END )? \z/;

# A duration in whole hours, as step-ca takes it.
my $HOURS = qr/\A [[:digit:]]+ h \z/;

sub args {
    return (
        type       => 'object',
        properties => {
            steppath => {
                type        => 'string',
                pattern     => "$ABSOLUTE_PATH",
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
                pattern     => "$Trog::Patterns::DOTTED_VERSION",
                default     => $STEP_CA_VERSION,
                description => 'The step-ca release to install.  Pinned rather than tracked: see MAINTENANCE.md.',
            },
            constrain_to => {
                type        => 'string',
                pattern     => "$LABEL",
                description => "The one top-level domain this CA is allowed to issue for, written into the intermediate as a name constraint.  It is what stops a key shipped to a throwaway guest from being trusted for anybody else: see perldoc Provisioner::Recipe::acmeca.  Defaults to the top-level domain of the guest this CA is built for, which is the only name it has any business issuing.",
            },
            default_duration => {
                type        => 'string',
                pattern     => "$HOURS",
                default     => '24h',
                description => 'How long a certificate this CA issues is good for when the client asks for no particular lifetime.',
            },
            max_duration => {
                type        => 'string',
                pattern     => "$HOURS",
                default     => '2160h',
                description => 'The longest lifetime this CA will issue, whatever the client asks for.  Ninety days by default, which is what the public CA this stands in for allows.',
            },
        },
    );
}

=head2 $recipe->enrich(%opts)

Sets C<constrain_to> to the top-level domain of C<$opts{domain}>, unless the
domain already names one.  A CA on a guest issues that guest its certificate.
So the top-level domain of the guest is the only one it vouches for.

A schema default cannot depend on another field, so this happens here and not
in C<args>.

Returns the options, with C<constrain_to> set.

Dies if C<constrain_to> is not set and C<domain> has no top-level domain.

    my %opts = $recipe->enrich( domain => 'guest.test.test' );

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{constrain_to} //= Provisioner::Utils::tld_of( $opts{domain} );
    die "acmeca could not tell what top-level domain to constrain itself to from '" . ( $opts{domain} // q{} ) . "'; set constrain_to for this domain\n"
      unless $opts{constrain_to};

    return %opts;
}

=head2 $recipe->port_for($domain)

The C<port> that C<$domain> configures for this recipe, or else the default of
the schema.  It reads the configuration that the environment names, from
L<Provisioner::Cookbook>, and not the options of a recipe.  So a recipe that
asks this CA for something gets the port where the CA answers.

=over 4

=item domain - Str - the domain whose configuration to read

=back

Returns Int, the port.

    my $port = $recipe->port_for('guest.test.test');

=cut

sub port_for {
    my ( $self, $domain ) = @_;

    return ( Provisioner::Cookbook->domain_config($domain)->{ $self->recipe_name } // {} )->{port} // $DEFAULT_PORT;
}

=head2 $recipe->fleet_ca_of($domain)

Returns the guest whose CA issues the certificate of C<$domain>, where that is
not the guest of C<$domain>, and undef otherwise.

That guest is the authority of the registrar of C<$domain>, where both are
under the same reserved TLD.  The constraint of the intermediate of the
authority permits that TLD.  If the authority names an authority of its own, it
runs no CA, and the answer is the CA of that one in turn.

=over 4

=item domain - Str - the domain that wants a certificate

=back

Returns Str, the name of the guest, or undef.

    my $guest = $recipe->fleet_ca_of('guest.test.test');

=cut

sub fleet_ca_of {
    my ( $self, $domain ) = @_;

    my $tld       = Provisioner::Utils::reserved_tld($domain) // return;
    my $registrar = Provisioner::Cookbook->load('registrar');

    my ( $ca, %seen );
    while ( defined( my $authority = $registrar->delegated_to($domain) ) ) {
        last unless ( Provisioner::Utils::reserved_tld($authority) // q{} ) eq $tld;
        last if $seen{$authority}++;
        $ca = $domain = $authority;
    }

    return $ca;
}

=head2 $recipe->directory_for($domain)

The ACME directory that dehydrated asks for the certificate of C<$domain>: the
CA of C<fleet_ca_of>, through the API of that guest, or else the CA on the
guest, on loopback at C<port_for>.

=over 4

=item domain - Str - the domain that wants a certificate

=back

Returns Str, the URL of the directory.

    my $url = $recipe->directory_for('guest.test.test');

=cut

sub directory_for {
    my ( $self, $domain ) = @_;

    my $guest = $self->fleet_ca_of($domain);
    return "https://dnsapi.$guest/acme/trog/directory" if defined $guest;

    return 'https://localhost:' . $self->port_for($domain) . '/acme/trog/directory';
}

=head2 $recipe->fetch_hosts()

The hosts that serve the releases of GitHub, where the fragment downloads
step-ca, as C<github_release_hosts> gives them.

Returns a list of host names.

    my @hosts = $recipe->fetch_hosts();

=cut

sub fetch_hosts {
    my ($self) = @_;

    return $self->github_release_hosts();
}

=head2 $recipe->template_files()

F<acmeca.ca.json> and F<acmeca.service>, from the templates of the same name
with C<.tt> after it.  It takes no list of recipes, because the files are the
same on every guest.

Returns a list of pairs, from each template to the name of the file that it
renders in the configuration directory.

    my %files = $recipe->template_files();

=cut

sub template_files {
    return (
        'acmeca.ca.json.tt' => 'acmeca.ca.json',
        'acmeca.service.tt' => 'acmeca.service',
    );
}

=head2 $recipe->generate_files($output_dir, %vars)

Writes the configuration and the unit, and then the key material that the CA
issues from.  See C<intermediate>.

=over 4

=item output_dir - Str - the configuration directory of the domain

=back

C<%vars> are the template variables, which are validated for
C<constrain_to>.

Returns a list of the names of the files that it wrote.

Dies when C<intermediate> dies.

    my @written = $recipe->generate_files( $output_dir, domain => 'guest.test.test' );

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my @written = $self->SUPER::generate_files( $output_dir, %vars );
    my %opts    = $self->validated(%vars);

    return ( @written, $self->intermediate( $output_dir, $opts{constrain_to} ) );
}

=head2 $class->issuing_authority()

The authority that this CA issues from, as a hash reference of C<cert> and
C<key>, the paths of the two files:

=over 4

=item * The authority of the fetch cache, where this installation holds its key
or holds nothing yet.  The first of the cache and this CA to ask makes it, and
both keep it.  So a fleet with a cache and a CA has one root.  See
L<Provisioner::Recipe::fetchcache/authority>.

=item * An authority of its own, in F<acmeca-ca.crt> and F<acmeca-ca.key>
beside F<ips.db>, where this installation holds the certificate of the cache
and not its key.  Such an installation trusts a cache that another one signed,
as a scratch configuration does, and it cannot sign with that authority.  It
still issues to its guests, because SSL on a guest under a reserved TLD has no
other issuer.  This makes the pair the first time, and keeps it.

=back

Returns a HashRef of C<cert> and C<key>.

Dies if F<acmeca-ca.crt> is there without its key, for the reason that
L<Provisioner::Recipe::fetchcache/authority> dies.

    my $paths = Provisioner::Recipe::acmeca->issuing_authority();

=cut

Readonly my $AUTHORITY_DAYS => 3650;

sub issuing_authority {
    my ($class) = @_;

    my %own   = ( cert => Trog::Config->path('acmeca-ca.crt'),     key => Trog::Config->path('acmeca-ca.key') );
    my %cache = ( cert => Trog::Config->path('fetchcache-ca.crt'), key => Trog::Config->path('fetchcache-ca.key') );

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether each file of a pair was made, not whether it can be read
    return \%own if -f $own{cert} && -f $own{key};
    die "There is $own{cert}, but no $own{key} to sign with.  To make a new authority for acmeca, remove $own{cert}, and copy the new one to each installation that trusts it.\n"
      if -f $own{cert};
    return Provisioner::Cookbook->load('fetchcache')->authority() if !-f $cache{cert} || -f $cache{key};

    Provisioner::Utils::write_authority( @own{qw(cert key)}, 'trog-provisioner acme authority', $AUTHORITY_DAYS );
    return \%own;
}

=head2 $class->trusted_root()

The certificate of the authority that this CA issues from, as
C<issuing_authority> chooses it, but never made: F<acmeca-ca.crt> where this installation made one,
or else the certificate of the fetch cache, from
L<Provisioner::Recipe::fetchcache/trusted_authority>, which dies when there is
none.

Returns Str, the path of the certificate.

    my $path = Provisioner::Recipe::acmeca->trusted_root();

=cut

sub trusted_root {
    my ($class) = @_;

    my $own = Trog::Config->path('acmeca-ca.crt');
    return $own if -f $own;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether this installation made one
    return Provisioner::Cookbook->load('fetchcache')->trusted_authority();
}

=head2 $recipe->intermediate($output_dir, $tld)

Signs an intermediate with C<issuing_authority>, constrained to names under C<$tld>
and C<localhost>.  Writes it into C<$output_dir> as
F<acmeca-intermediate.crt>, and its key as F<acmeca-intermediate.key>.  Also
writes the authority as F<acmeca-root.crt>, which the guest chains to and
trusts.

=over 4

=item output_dir - Str - the directory to write the three files into

=item tld - Str - the top-level domain that the intermediate may issue for

=back

Only the certificate of the root travels.  Its key stays where it was made.

Returns a list of the three file names.

Dies if it cannot copy the certificate of the authority.

    my @written = $recipe->intermediate( $output_dir, 'test' );

=cut

sub intermediate {
    my ( $self, $output_dir, $tld ) = @_;

    my $authority = $self->issuing_authority();
    my $ca_cert   = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $ca_key    = IO::Socket::SSL::Utils::PEM_file2key( $authority->{key} );

    my ( $cert, $key ) = IO::Socket::SSL::Utils::CERT_create(

        # CA sets basicConstraints and the key usage that step-ca signs with.
        # The name constraint goes in ext, because no argument sets one.  Do not
        # add basicConstraints to ext, because CA already gives it to OpenSSL.
        CA        => 1,
        subject   => { commonName => "trog-provisioner acme intermediate for .$tld" },
        issuer    => [ $ca_cert, $ca_key ],
        not_after => int(time) + $INTERMEDIATE_DAYS * $Provisioner::Vars::SECONDS_A_DAY,
        key       => IO::Socket::SSL::Utils::KEY_create_ec('prime256v1'),
        ext       => [ { sn => 'nameConstraints', data => "critical,permitted;DNS:.$tld,permitted;DNS:localhost" } ],
    );

    Trog::Utils::write_binary_mode( "$output_dir/acmeca-intermediate.key", IO::Socket::SSL::Utils::PEM_key2string($key),   oct('0600') );
    Trog::Utils::write_binary_mode( "$output_dir/acmeca-intermediate.crt", IO::Socket::SSL::Utils::PEM_cert2string($cert), oct('0644') );

    for my $item ( $cert, $ca_cert ) { IO::Socket::SSL::Utils::CERT_free($item); }
    for my $item ( $key,  $ca_key )  { IO::Socket::SSL::Utils::KEY_free($item); }

    File::Copy::copy( $authority->{cert}, "$output_dir/acmeca-root.crt" )
      or die "Could not give the guest the authority to chain to: $!\n";

    return qw{acmeca-root.crt acmeca-intermediate.crt acmeca-intermediate.key};
}

=head2 $recipe->tests()

Returns a list of the test templates that run on the guest: F<acmeca.tt>.

    my @tests = $recipe->tests();

=cut

sub tests {
    return qw{acmeca.tt};
}

1;
