package Provisioner::DNSRecipe;

#ABSTRACT: Base class for a recipe that can answer a dns-01 challenge for a domain.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};
use Scalar::Util();

use Provisioner::Cookbook();
use Provisioner::Utils();

=head1 NAME

Provisioner::DNSRecipe - which server holds the zone of a domain, and how
lexicon gets to it.

=head1 SYNOPSIS

    package Provisioner::Recipe::pdns;
    use parent qw{Provisioner::DNSRecipe};

    sub lexicon_credentials {
        my ( $self, %opts ) = @_;
        return (
            type  => 'powerdns',
            user  => q{},
            key   => $opts{api_key},
            opts  => '--resolve-zone-name',
            extra => [ { key => 'PDNS_SERVER', value => '/var/spool/powerdns/api.sock' } ],
        );
    }

=head1 DESCRIPTION

To answer a C<dns-01> challenge, something writes an C<_acme-challenge> record
into the zone of the domain.  Two kinds of server hold a zone here.  The first
is the C<pdns> server that a guest runs for its own name.  The second is the
registrar that holds a public zone.  To lexicon, each one is a provider, a
credential, and sometimes an endpoint.

A recipe that can answer a challenge inherits from this class.  It tells what
lexicon needs to get to its server.  Everything that writes a record renders
from that one answer.  This includes the dehydrated hook of
L<Provisioner::Recipe::letsencrypt>, and the shortcut for each domain that
L<Provisioner::Recipe::lexicon> installs.

=head2 It is a recipe in the ordinary way

This class sits between L<Provisioner::Recipe> and the recipes that implement
it.  L<Provisioner::DistroRecipe> does the same for a distribution.  An
implementation is a recipe like all others.  It declares C<args>, it gets its
configuration from F<recipes.yaml>, and it renders a fragment if it has
something to install.  This class adds one question that it must answer:
C<lexicon_credentials>.

=head2 Which implementation a domain uses

The guest serves a domain under a reserved TLD itself, because no public
registrar can hold a zone for one.  A domain with registrar credentials and no
local server uses the registrar.  If a guest has both, the C<dns_preference> of
L<Provisioner::Recipe::letsencrypt> tells which one holds the zone.  See
C<implementation_for> for the full rules.

=cut

our $LOCAL_IMPLEMENTATION = 'pdns';

# RFC 2606 and RFC 6761 keep these for documentation, testing and private use.
# So no public registrar holds a zone under one, and only the guest can serve it.
our @RESERVED_TLDS = qw{test example invalid localhost};

=head1 METHODS AN IMPLEMENTATION MUST ANSWER

=head2 %credentials = $recipe->lexicon_credentials(%opts)

Returns how lexicon gets to the server that holds the zone of this domain, as
these keys:

=over 4

=item * C<type>: the name of the lexicon provider.  This name also names the
environment variables of the provider and the shortcut installed for it.

=item * C<user>: the account, if the provider wants one.  Usually it is empty,
because most providers take only a token.

=item * C<key>: the token that lexicon authenticates with.

=item * C<opts>: flags that every lexicon command for this provider needs, as a
string.  Usually it is empty.

=item * C<extra>: provider options other than the credential, as a list of
C<{ key =E<gt> ..., value =E<gt> ... }>.  Each one becomes
C<LEXICON_E<lt>TYPEE<gt>_E<lt>KEYE<gt>>.  Lexicon makes the name of an
environment variable from the provider name and the option name.  So
C<--pdns-server> is C<PDNS_SERVER> here, and the provider goes around it.

=back

This class does not answer it, and dies.  Without this answer, the hook exports
nothing and fails in the middle of an order.  An early failure is better.

=cut

sub lexicon_credentials { return shift->_unanswered('lexicon_credentials') }

=head2 $name = $recipe->local_implementation()

Returns the implementation that runs on the guest itself: C<pdns>.

Require it when only a server on this guest will do.  For example,
L<Provisioner::Recipe::acmeca> validates a C<dns-01> challenge through the
resolver of the host.  So a registrar can never serve that challenge.

=cut

sub local_implementation { return $LOCAL_IMPLEMENTATION }

=head2 $key = $recipe->tiebreaker_key()

Returns the configuration key that names the implementation a recipe prefers,
when more than one can answer: C<dns_preference>.

C<implementation_for> reads its preference from this key.  A recipe that hands
a preference down to another recipe uses this key to name it.
L<Provisioner::Recipe::letsencrypt> does this for
L<Provisioner::Recipe::lexicon>.

=cut

sub tiebreaker_key { return 'dns_preference' }

=head2 @tlds = $recipe->reserved_tlds()

Returns the top-level domains that no public registrar holds a zone under.  No
public CA issues a certificate for a name under one of them.

L<Provisioner::Recipe::letsencrypt> uses this list to choose the CA.  Ask for
the list with this method.  Do not keep a second copy of it.

=cut

sub reserved_tlds { return @RESERVED_TLDS }

=head2 $name = $recipe->implementation_for(%opts)

Returns the implementation that serves the zone of C<domain>: C<pdns> if the
guest holds it, and C<registrar> if another party holds it.

It takes these options:

=over 4

=item * C<domain>: the domain to ask about.

=item * C<configured>: the configuration of the domain, as a hash reference.
Required.

=item * C<host>: the guest that the domain is layered onto, if there is one.
Error messages name it.

=item * C<host_configured>: the configuration of that guest, as a hash
reference, or undef.

=item * C<dns_preference>: optional.  The key is the one that
C<tiebreaker_key> names.

=back

The caller passes the configurations in, and this method does not fetch them.
Provisioner::Cookbook answers about the configuration that the environment
names.  But F<bin/new_config> takes C<--recipes>, so the configuration of the
run can be a different one.  Only the caller knows which one applies.

Ask this method, and do not work out the answer again.  The depsolver in
C<resolve_substitutable_dependency> in
L<Provisioner::Cookbook> and
L<Provisioner::Recipe::letsencrypt> both ask it.  It reads the configuration of
the domain, not the module list, because the depsolver changes that list.

It does not guess.  It dies in these conditions:

=over 4

=item * C<configured> is not a hash reference.

=item * The preference names the registrar for a name under a reserved TLD.
No registrar can answer for such a name.

=item * The preference names C<pdns>, but the guest has no C<pdns>
configuration.

=item * The guest has both, and no preference names one of them.

=item * The guest has neither.

=back

=cut

sub implementation_for {
    my ( $class, %opts ) = @_;

    my $domain   = $opts{domain};
    my $reserved = Provisioner::Utils::tld_of($domain);
    $reserved = ( defined $reserved && any { $_ eq $reserved } @RESERVED_TLDS ) ? $reserved : undef;

    die "implementation_for was not told what $domain is configured with; pass configured => the domain's recipes.\n"
      unless ref $opts{configured} eq 'HASH';

    my $server = $opts{host} // $domain;

    # Look in the host configuration too, because the guest that a domain is
    # layered onto serves it.
    my @where     = ( $opts{configured}, $opts{host_configured} );
    my $local     = ( $reserved || _configures( $LOCAL_IMPLEMENTATION, @where ) ) ? 1 : 0;
    my $registrar = _configures( 'registrar', @where );

    my $stated = $opts{ $class->tiebreaker_key };
    if ($stated) {
        die "$domain is under .$reserved, which RFC 2606 and RFC 6761 reserve, so no public registrar can hold a zone for it -- dns_preference: registrar names a provider that could never answer its challenge.  The guest serves this name itself; drop the preference.\n"
          if $stated eq 'registrar' && $reserved;

        die "$domain asks for dns_preference: $LOCAL_IMPLEMENTATION, but $server is configured with no $LOCAL_IMPLEMENTATION recipe, so nothing on the guest could answer its dns-01 challenge.  Add $LOCAL_IMPLEMENTATION, or name the registrar that holds the zone.\n"
          if $stated eq $LOCAL_IMPLEMENTATION && !$local;

        return $stated;
    }

    # A registrar cannot serve a reserved TLD, so inherited credentials do not
    # make a tie.
    return $LOCAL_IMPLEMENTATION if $reserved;

    return 'registrar'           if $registrar && !$local;
    return $LOCAL_IMPLEMENTATION if $local     && !$registrar;

    die "$domain is configured with both a DNS server of its own and registrar credentials, and either could answer its dns-01 challenge.  Set dns_preference to '$LOCAL_IMPLEMENTATION' or 'registrar' to say which one holds the zone this name is served from.\n"
      if $local && $registrar;

    die "$domain has no DNS provider that could answer a dns-01 challenge: set registrar credentials for its zone, or add the $LOCAL_IMPLEMENTATION recipe so the guest serves the zone itself.\n";
}

=head2 $name = $recipe->provider_for(%opts)

Returns the implementation that serves C<$opts{domain}>.  It reads the
configuration that the environment names, from L<Provisioner::Cookbook>.

This is C<implementation_for>, but it fetches the three configurations itself.
If you already have them, call C<implementation_for>, as the depsolver of
F<bin/new_config> does.  If not, call this method.  It dies as
C<implementation_for> does.

=cut

sub provider_for {
    my ( $class, %opts ) = @_;

    my $host = Provisioner::Cookbook->host_of( $opts{domain} );

    return $class->implementation_for(
        %opts,
        configured      => Provisioner::Cookbook->domain_config( $opts{domain} ) // {},
        host            => $host,
        host_configured => ( defined $host ? Provisioner::Cookbook->domain_config($host) : undef ),
    );
}

=head2 %credentials = $recipe->credentials_for(%opts)

Returns what lexicon needs to get to the server that holds the zone of
C<$opts{domain}>.  It asks C<provider_for> for the provider, and then asks that
provider for its C<lexicon_credentials>.

It dies as C<provider_for> does.  It also dies, with the name of the provider,
if this installation has no recipe for that provider, or if that recipe cannot
answer a challenge.

=cut

sub credentials_for {
    my ( $class, %opts ) = @_;

    my $provider = $class->provider_for(%opts);

    return $class->_implementation($provider)->lexicon_credentials( _provider_config( $provider, %opts ) );
}

=head2 $class = $recipe->_implementation($provider)

Returns the class of the recipe that implements C<$provider>.  It loads the
class and does not make an object.  An object needs C<template_dirs>, which a
caller of this method has no reason to know.  C<lexicon_credentials> reads only
its arguments, so the class is enough.

Dies if no recipe has that name, or if the recipe is not a
Provisioner::DNSRecipe.

=cut

sub _implementation {
    my ( $class, $provider ) = @_;

    my $impl = eval { Provisioner::Cookbook->load($provider) };
    die "$provider is not a recipe this installation has, so nothing can answer a dns-01 challenge through it.\n" unless $impl;
    die "$provider cannot answer a dns-01 challenge: it is not a Provisioner::DNSRecipe.\n"                       unless $impl->isa('Provisioner::DNSRecipe');

    return $impl;
}

=head2 %args = _provider_config($provider, %opts)

Returns the arguments for C<lexicon_credentials>: the configuration block of
C<$provider> for C<$opts{domain}>, and C<domain>.  If the domain has no block,
it uses the block of the guest that the domain is layered onto.

It returns only what the operator configured.  If a credential is missing, the
implementation decides what to do.  See C<api_key_for> in
L<Provisioner::Recipe::pdns>.

=cut

sub _provider_config {
    my ( $provider, %opts ) = @_;

    my $server = Provisioner::Cookbook->host_of( $opts{domain} ) // $opts{domain};
    my $conf   = Provisioner::Cookbook->domain_config( $opts{domain} )->{$provider} // Provisioner::Cookbook->domain_config($server)->{$provider} // {};

    return ( %{$conf}, domain => $opts{domain} );
}

=head2 $bool = _configures($recipe, @where)

Returns 1 if C<$recipe> is a key in one of the hash references in C<@where>,
and 0 if not.  It ignores an element that is not a hash reference.  See
C<implementation_for> for why the caller passes the configurations in.

=cut

sub _configures {
    my ( $recipe, @where ) = @_;

    foreach my $conf ( grep { ref $_ eq 'HASH' } @where ) {
        return 1 if exists $conf->{$recipe};
    }

    return 0;
}

sub _unanswered {
    my ( $self, $what ) = @_;

    my $recipe = Scalar::Util::blessed($self) || $self;
    $recipe =~ s/\AProvisioner::Recipe::(?:\w+::)?//;

    die "The $recipe recipe does not say what its $what is.\n" . "Every recipe that can answer a dns-01 challenge has to answer that before\n" . "anything can write a record through it; see perldoc Provisioner::DNSRecipe.\n";
}

1;
