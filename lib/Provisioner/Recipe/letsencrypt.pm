package Provisioner::Recipe::letsencrypt;

#ABSTRACT: Issue and install TLS certificates via dehydrated and DNS DCV.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

use Provisioner::Cookbook();
use Provisioner::DNSRecipe();
use Provisioner::Utils();

=head1 Provisioner::Recipe::letsencrypt

=head2 SYNOPSIS

    somedomain:
        letsencrypt:

=head2 DESCRIPTION

This recipe configures lexicon to update the TXT records of your domain at your
registrar, so that you can do DNS DCV (domain control validation).

It configures dehydrated to do DNS DCV with lexicon.

L<Provisioner::Recipe::lexicon> puts the client on the guest.  It also installs
the per-domain shortcut to run the client by hand:

    /opt/lexicon/my.domain.name list TXT

The recipe also keeps a local copy of each certificate that it provisions.  Then
repeated redeploys do not break the terms of service or hit the rate limit.

The user that runs new_config must have a key that is authorized for the admin
user on the remote host.

=head2 What the salvage needs to be able to read

C<remote_files> names the two certificate directories and the account directory.
The certificates in them are of no use without their keys.  A guest that gets
certificates back without their keys issues again from scratch, and the salvage
exists to prevent that.  A new issue spends the rate limit of Let's Encrypt.  If
the account key is also lost, it spends the registration too.  The old
certificates stay valid, but nothing can revoke them, and the CA does not know
the guest.

On the guest, the certificates are world readable, because they are public.
dehydrated writes each private key and the account key as C<0600 root>.  The
fetch reads the guest as root, so nothing here makes them wider.

Three places set these modes again, one for each moment that a new key exists:

=over 4

=item * The global fragment, after C<dehydrated --register> writes the account
key.

=item * C<get_cert>, after the provision.

=item * The C<exit_hook> in the dehydrated hook of this domain, after B<every>
dehydrated run.  The nightly renewal writes a new private key and does not run
C<get_cert>.

=back

Know this about the other end of the fetch.  The keys land in the data directory
of the provisioner and in whatever backs it up.  So that directory holds the TLS
private keys of this domain.

The C<data> target puts the account back before any recipe target runs.  So the
account is in place before the global fragment runs C<dehydrated --register>,
and C<restore_state> does not write over an account that is already there.

This is how it works for the public CA.  An account that a CA on this guest
issued does not go back at all.  See C<restores>.

=head2 Which CA issues, and how a reserved TLD gets one at all

C<ca> is a dehydrated preset name or the URL of a directory.  Its default
depends on the domain, not on one value.  A name under a public suffix gets the
public Let's Encrypt directory.  A name under a TLD that RFC 2606 and RFC 6761
reserve gets the CA of this fleet.  These TLDs are C<.test>, C<.example>,
C<.invalid> and C<.localhost>.  No public CA issues for them.  Let's Encrypt
refuses such an order with C<rejectedIdentifier>, I<Domain name does not end
with a valid public suffix (TLD)>.

This default pulls in L<Provisioner::Recipe::acmeca>, which serves the CA.
acmeca pulls in L<Provisioner::Recipe::pdns>, which answers the C<dns-01>
challenge on loopback.  pdns needs an C<api_key> that nobody configured, so
this recipe supplies one.  It makes one key for each guest and gives it to both
pdns and lexicon, because lexicon authenticates with the value that pdns uses.
If an operator set an C<api_key>, the operator keeps it and this recipe supplies
nothing.  A second value for a field that the operator set is the conflict that
C<resolve_conflict> dies on.

B<The recipe asks this of the domain, not of the module list.>  The pdns on the
guest serves a reserved TLD, and this recipe requires that server through
acmeca.  So the server is always there when the name needs it.  Do not ask
C<modules>.  The depsolver adds to it between C<required_recipes> and C<enrich>,
so the two get different answers about the same domain.

=head2 Which provider answers the challenge

C<dns_preference> names the provider.  C<pdns> is the server that this fleet
runs on the guest.  C<registrar> is the holder of the public zone of the domain.
It is a tiebreaker, not a setting.  Usually nothing needs it.  A name under a
reserved TLD always uses the local server, because no public registrar can hold
a zone for it.  A domain configured with only one of the two uses that one.

It matters when a guest has both, which is a public name whose zone this fleet
also serves.  The registrar and the local server can each answer, and they
answer differently.  A choice on behalf of the domain is a guess.  So the recipe
refuses a domain that configures both and names neither.

The recipe also refuses two configurations.  C<registrar> under a reserved TLD
names a provider that can never answer for the name.  C<pdns> with no such
server configured names a provider that is not there.

=head2 What a guest served by our own CA can be issued for

It can get certificates for names inside its own zone, and for nothing else.

L<Provisioner::Recipe::pdns> builds one zone for each guest, which is the domain
itself.  So C<www.> and C<mail.> are inside it and work.  An alias outside the
zone has no place for lexicon to write C<_acme-challenge>, and no local server
is authoritative for it.  A cross-TLD alias is the obvious case, but the rule is
the zone and not the TLD.  C<test.example.net> as an alias of
C<dev.example.net> is also out of the zone.

The CA does not set this limit.  C<nameConstraints> takes a list, so one
intermediate can permit several TLDs, and the leaf certificates under each of
them verify.  The challenge is the limit.

=cut

sub template_files {
    my ($self) = @_;

    return (
        'ssl.get_cert.tt'             => 'get_cert',
        'ssl.dehydrated.conf.tt'      => 'dehydrated.conf',
        'ssl.dehydrated.domain.tt'    => 'dehydrated.domain',
        'ssl.dehydrated.hook.tt'      => 'domain.hook',
        'ssl.domains.tt'              => 'domains.txt',
        'ssl.dehydrated.logrotate.tt' => 'dehydrated.logrotate',
    );
}

sub datadirs {
    return ('.letsencrypt');
}

# The dehydrated preset for the public Let's Encrypt directory.  A domain that
# names no CA gets this one.
our $DEFAULT_CA = 'letsencrypt';

=head2 $tld = _reserved_tld($domain)

Returns the TLD of C<$domain> if only our own CA can issue for it.  Otherwise
returns nothing.

The list of TLDs comes from L<Provisioner::DNSRecipe>.  No public registrar
holds a zone under one of them, for the same reason that no public CA issues for
a name under one.  So a guest under one gets its certificate from the CA of the
fleet, or it gets none.

=cut

sub _reserved_tld {
    my ($domain) = @_;

    my $tld = Provisioner::Utils::tld_of($domain) or return;

    return ( any { $_ eq $tld } Provisioner::DNSRecipe->reserved_tlds ) ? $tld : ();
}

=head2 $bool = _auto_ca(%opts)

Returns 1 if the CA of this domain is ours by default and not by name.  That is
the case when C<ca> is not set and the domain is under a reserved TLD.
Otherwise returns 0.

It reads the raw options.  C<required_recipes> runs before validation, so an
absent C<ca> is still absent and not defaulted.  That is how it tells a domain
that chose the public CA from a domain that named none.

=cut

sub _auto_ca {
    my (%opts) = @_;

    return ( !defined $opts{ca} && _reserved_tld( $opts{domain} ) ) ? 1 : 0;
}

=head2 $bool = _our_ca(%opts)

Returns 1 if this domain needs a CA of ours built for it.  That is the case when
it names a C<ca> other than C<$DEFAULT_CA>, or when C<_auto_ca> returns 1.
Otherwise returns 0.

=cut

sub _our_ca {
    my (%opts) = @_;

    return 1 if defined $opts{ca} && $opts{ca} ne $DEFAULT_CA;
    return _auto_ca(%opts);
}

=head2 $bool = _ca_rebuilt_with_guest(%opts)

Returns 1 if a rebuild of the guest also rebuilds the CA that issues for this
domain.  Otherwise returns 0.  C<restores> asks this to decide whether the ACME
account goes back.  This is a narrower question than C<_our_ca>.

The answer is 1 when C<ca> is not set and the domain is under a reserved TLD.
It is also 1 when C<ca> is a URL whose host is C<localhost> or C<127.0.0.1>.

acmeca runs on the guest, on loopback.  Each provision starts it with an empty
database and a new intermediate.  So it does not know an account that it issued
before, and every order on that account returns C<accountDoesNotExist>.

Every other CA outlives the guest.  That includes a CA that is neither Let's
Encrypt nor ours, such as C<buypass>, C<zerossl>, or an internal CA on another
machine.  An account with one of them is the identity of this installation with
a third party, and the recipe keeps it on purpose.  If the recipe drops it, the
rebuild registers again for nothing.  With Let's Encrypt, that also breaks their
terms.

=cut

sub _ca_rebuilt_with_guest {
    my (%opts) = @_;

    return 1 if !defined $opts{ca} && _reserved_tld( $opts{domain} );
    return 0 unless defined $opts{ca};

    my $host = Provisioner::Utils::host_of( $opts{ca} ) // q{};

    return ( $host eq 'localhost' || $host eq '127.0.0.1' ) ? 1 : 0;
}

=head2 $url = _directory_url($domain)

Returns the URL of the ACME directory where acmeca answers for C<$domain>.  The
port is the acmeca C<port> that the domain configured.  If the domain configured
none, the port is the default from the acmeca schema.

This reads the port and does not set it.  The operator can also configure the
acmeca port, and C<Provisioner::Recipe::resolve_conflict> dies on a second value
for a field that the operator set.

=cut

sub _directory_url {
    my ($domain) = @_;

    my $configured = Provisioner::Cookbook->domain_config($domain)->{acmeca}{port};
    my %args       = Provisioner::Cookbook->load('acmeca')->args();
    my $port       = $configured // $args{properties}{port}{default};

    return "https://localhost:$port/acme/trog/directory";
}

sub args {
    return (
        type       => 'object',
        properties => {
            ca => {
                type        => 'string',
                description =>
                  "Which ACME server issues this domain's certificate: a dehydrated preset name, or the URL of a directory.  Defaults to '$DEFAULT_CA', the public one -- except under a reserved TLD, where no public CA can issue at all and this becomes the fleet's own, pulling in the acmeca recipe that serves it.  Naming anything but the default preset also pulls that recipe in.  No default is declared here because the answer depends on the domain.",
            },
            dns_preference => {
                type        => 'string',
                enum        => [qw{pdns registrar}],
                description =>
                  "Which DNS recipe answers this domain's dns-01 challenge where the guest has more than one that could: 'pdns' for the server this fleet runs on the guest, 'registrar' for whoever holds the public zone.  A tiebreaker and nothing more -- a name under a reserved TLD is always served locally, and a domain configured with only one of the two uses it -- so a guest with both and no preference is refused rather than guessed at.  Resolved by enrich to the provider actually used, which is what the hook and the fetcher are rendered from.",
            },
        },
    );
}

sub enrich {
    my ( $self, %params ) = @_;

    die "prefer_local_dns is now dns_preference, which names the recipe that answers this domain's challenge rather than asserting a boolean: 'pdns' for the server on the guest, 'registrar' for whoever holds the public zone.\n"
      if exists $params{prefer_local_dns};

    # Nothing reads registrar credentials in _global.  Refuse them, because the
    # domain otherwise resolves to no provider or to the guest without a word.
    die "registrar credentials belong to the registrar recipe now, not to _global, so nothing reads the ones set for $params{domain}.  Move the registrar block out of _base._global and into _base, where it configures Provisioner::Recipe::registrar for every domain that inherits it.\n"
      if ref $params{registrar} eq 'HASH' && !exists( Provisioner::Cookbook->domain_config( $params{domain} )->{registrar} );

    my $provider = Provisioner::DNSRecipe->provider_for(%params);

    # The default CA depends on the domain: see L</Which CA issues, and how a
    # reserved TLD gets one at all>.
    $params{ca} = _directory_url( $params{domain} ) if _auto_ca(%params);
    $params{ca} //= $DEFAULT_CA;

    # The rest of the render uses the resolved provider, because a domain that
    # names no preference still has one.
    $params{dns_preference} = $provider;

    # The same name and structure that the shortcut renders from, so the two
    # exports of one credential cannot drift apart.
    $params{lexicon} = { Provisioner::DNSRecipe->credentials_for(%params) };

    # The socket lexicon talks to, where the provider is reached through one,
    # which get_cert waits for before it asks for a challenge.
    my %extra = map { $_->{key} => $_->{value} } @{ $params{lexicon}{extra} // [] };
    $params{lexicon_socket} = $extra{PDNS_SERVER} // q{};

    return %params;
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The certificates, so that a rebuild does not request them again against
    # the rate limit.
    my %restores = ( "/var/lib/dehydrated/certs/$domain" => { from => "$install_dir/$domain/.letsencrypt/var-certs/$domain", owner => 'root:root' } );

    # The ACME account goes back only for a CA that outlives the guest.  See
    # _ca_rebuilt_with_guest.
    return %restores if _ca_rebuilt_with_guest(%opts);

    return ( %restores, '/etc/dehydrated/accounts' => { from => "$install_dir/$domain/.letsencrypt/accounts", owner => 'root:root' } );
}

# Not /etc/dehydrated/certs.  dehydrated has BASEDIR=/var/lib/dehydrated, so it
# never writes there, and an empty salvage raises a warning on every run.
sub remote_files {
    return (
        '/var/lib/dehydrated/certs/' => '.letsencrypt/var-certs',
        '/etc/dehydrated/accounts/'  => '.letsencrypt/accounts',
    );
}

=head2 %required = $recipe->required_recipes(%opts)

Returns the recipes that this one requires.  Each name comes with a sub that
returns the options to give that recipe:

=over 4

=item * C<acmeca>, when this domain uses a CA of the fleet and not a public
preset.

=item * The local DNS recipe (C<pdns>), with an C<api_key>, when the CA is ours
by default and nobody configured a key for the server.

=item * C<Provisioner::DNSRecipe>, which bin/new_config resolves to whatever
holds the zone of this domain.

=item * C<nostubresolver>, when the local server answers the challenge.

=item * C<lexicon>, with the resolved provider as its tiebreaker.

=back

It also returns what the base class requires.

The recipe gives acmeca no options, because the configuration of a CA is its own
business.  The acmeca edge exists for the order.  bin/new_config puts a required
recipe after the last recipe that requires it and before the postrun.  The
fetcher that this recipe queues asks the CA for a certificate during the
postrun.  So the dependency makes sure that the CA answers by then.  It does not
depend on where two recipes happen to sit in a list.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my @required = _our_ca(%opts) ? ( acmeca => sub { return () } ) : ();

    # acmeca requires pdns and gives it no api_key.  Supply one only when this
    # recipe is why pdns is there and the operator set none.  See L</Which CA
    # issues, and how a reserved TLD gets one at all>.
    if ( _auto_ca(%opts) ) {

        # The domain of the machine, not this one, because one pdns serves the
        # whole guest and already runs with its key.  Provisioner::Cookbook/host_of
        # finds the machine in _shared.
        my $server = Provisioner::Cookbook->host_of( $opts{domain} ) // $opts{domain};
        my $local  = Provisioner::DNSRecipe->local_implementation();
        my $class  = Provisioner::Cookbook->load($local);

        my $configured = Provisioner::Cookbook->domain_config($server)->{$local}{api_key};
        unless ($configured) {

            # Ask the recipe that owns the key, and ask now, because this runs
            # before validation and enrich has not run yet.  Every call gets the
            # same value for one server, so the server and its clients agree.
            my $token = $class->api_key_for($server);
            push( @required, $local => sub { return ( api_key => $token ) } );
        }
    }

    # The holder of the zone of this domain must be on the guest.  The registrar
    # recipe installs the shortcut for the operator, and pdns installs the
    # server.  The name is the interface, so bin/new_config resolves it to the
    # one that serves this domain.  See Provisioner::DNSRecipe and
    # resolve_substitutable_dependency.
    #
    # Skip it when the branch above already asked for the local recipe.  Under a
    # reserved TLD both resolve to the same recipe, and %dep_recipes is keyed by
    # recipe name.  So the second silently replaces the first, and the minted
    # api_key is lost for some orders that `keys` returns.
    push( @required, 'Provisioner::DNSRecipe' => sub { return () } )
      unless any { $_ eq Provisioner::DNSRecipe->local_implementation() } @required;

    # A guest that answers its own challenge must be able to read back what it
    # wrote.  lexicon walks the zone for --resolve-zone-name through the system
    # resolver, and step-ca validates dns-01 through it too.  On the systemd
    # stub, the guest cannot resolve its own name.  nostubresolver points the
    # resolver at the server on the guest.  It changes nothing on a fleet whose
    # _base already gives every domain that recipe.
    #
    # eval, because this runs before validation.  enrich rejects a domain with
    # no provider, and a second report here races two messages for one fault.
    my $provider = eval { Provisioner::DNSRecipe->provider_for(%opts) } // q{};
    push( @required, nostubresolver => sub { return () } ) if $provider eq Provisioner::DNSRecipe->local_implementation();

    # lexicon is the client that the hook writes the challenge record with.
    #
    # Give it the provider that this domain resolved to.  lexicon renders one
    # shortcut, for the holder of the zone, so it has the same tie to settle.
    # The key that settles it is in the block of this recipe, not of lexicon.
    push( @required, lexicon => sub { return $provider ? ( Provisioner::DNSRecipe->tiebreaker_key => $provider ) : () } );

    return ( @required, $self->SUPER::required_recipes(%opts) );
}

sub tests {
    return qw{letsencrypt.tt};
}

1;
