package Provisioner::DNSRecipe;

#ABSTRACT: Base class for a recipe that can answer a dns-01 challenge for a domain.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};
use Scalar::Util();

use Provisioner::Utils();

=head1 NAME

Provisioner::DNSRecipe - who holds a domain's zone, and how anything here
reaches it.

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

Writing an C<_acme-challenge> record means talking to whoever holds the zone,
and this fleet has two answers: the C<pdns> a guest runs for its own name, and
the registrar holding a public one.  They are the same thing to lexicon -- a
provider, a credential, and sometimes an endpoint -- and different in every
other way, which is what an interface is for.

A recipe that can answer such a challenge inherits from this and says what
lexicon needs to reach it.  Everything that writes a record renders from that
one answer: L<Provisioner::Recipe::letsencrypt>'s dehydrated hook, the
per-domain shortcut under F</opt/lexicon>, and the upstream section of
F</etc/synczones.conf>.  Before this they were three copies of the same
knowledge, and they had already drifted -- the shortcut named an environment
variable lexicon does not read, so it had never once been pointed at the API
socket.

=head2 It is a recipe in the ordinary way

This sits between L<Provisioner::Recipe> and the recipes that implement it, the
way L<Provisioner::DistroRecipe> does for a distribution.  An implementation is
a recipe like any other: it declares C<args>, it is configured out of
F<recipes.yaml>, it renders a fragment if it has anything to install.  What this
class adds is one question it has to answer.

=head2 Which implementation a domain uses

A domain under a reserved TLD is served by the guest itself, because no public
registrar can hold a zone for one.  A domain with registrar credentials and no
local server uses the registrar.  A guest with both is ambiguous, and
L<Provisioner::Recipe::letsencrypt>'s C<dns_preference> is the tiebreaker that
names which of the two holds the zone this name is served from.

=cut

# The implementation that runs on the guest itself.
our $LOCAL_IMPLEMENTATION = 'pdns';

# RFC 2606 and RFC 6761 keep these for documentation, testing and private use,
# so no public registrar holds a zone under one and the guest serves it or
# nothing does.
our @RESERVED_TLDS = qw{test example invalid localhost};

=head1 METHODS AN IMPLEMENTATION MUST ANSWER

=head2 %credentials = $recipe->lexicon_credentials(%opts)

How lexicon reaches the server holding this domain's zone, as:

=over 4

=item * C<type> -- the lexicon provider name, which is also what names its
environment variables and the shortcut installed for it.

=item * C<user> -- the account, where the provider wants one.  Empty is normal;
a token alone is what most of them take.

=item * C<key> -- the token lexicon authenticates with.

=item * C<opts> -- flags every lexicon invocation for this provider needs, as a
string.  Empty for most.

=item * C<extra> -- provider options beyond the credential, as a list of
C<{ key =E<gt> ..., value =E<gt> ... }>.  Each becomes
C<LEXICON_E<lt>TYPEE<gt>_E<lt>KEYE<gt>>, because lexicon derives an environment
variable from the provider name plus the option name -- so C<--pdns-server>
is C<PDNS_SERVER> here and the provider is prefixed around it.

=back

Dies in this class.  A recipe that cannot say how it is reached is not one
anything can write a record through, and saying so beats rendering a hook that
exports nothing and fails in the middle of an order.

=cut

sub lexicon_credentials { return shift->_unanswered('lexicon_credentials') }

=head2 $name = $recipe->local_implementation()

Which implementation runs on the guest itself: C<pdns>, the server this fleet
runs.

What to require when only a server on this guest will do.
L<Provisioner::Recipe::acmeca> validates a C<dns-01> challenge through the
host's own resolver, so a registrar could not serve it however the tiebreaker
fell.

=cut

sub local_implementation { return $LOCAL_IMPLEMENTATION }

=head2 $key = $recipe->tiebreaker_key()

Which configuration key names the implementation a recipe prefers, where more
than one could answer.  C<dns_preference>.

Declared here so C<bin/new_config> can resolve a substitutable dependency on
this interface without knowing anything about the recipes that declare one: it
asks the interface which key to read, and reads it out of the configuration of
whichever recipe asked.

=cut

sub tiebreaker_key { return 'dns_preference' }

=head2 @tlds = $recipe->reserved_tlds()

The top-level domains no public registrar holds a zone under, and so no public
CA will issue for: they are not public suffixes, so nobody can demonstrate
control of a name beneath one.

Asked rather than reached for.  L<Provisioner::Recipe::letsencrypt> needs the
same list to decide which CA issues, which is a different question from which
provider serves the zone -- but it is one list, and a second copy of it is a
second thing to keep right.

=cut

sub reserved_tlds { return @RESERVED_TLDS }

=head2 $name = $recipe->implementation_for(%opts)

Which implementation serves this domain's zone: C<pdns> where the guest holds
it, C<registrar> where somebody else does.

Dies rather than guessing, and there are three ways to be told so.  A registrar
named for a name under a TLD RFC 2606 reserves could never answer for it.  The
local server asked for where none is configured is not there.  And a guest
configured with both, naming neither, is a tie nothing here can settle -- so
C<tiebreaker_key> is what settles it.

C<configured> is what the domain is configured with and C<host_configured> what
the guest holding it is, for a domain layered onto another; C<host> names that
guest, and is used to say which one was looked at.  All three are passed in
rather than fetched -- see C<_configures>.

Asked of the domain's configuration rather than of the module list, because that
list is not the same before and after the depsolver has run: the two callers
here sit either side of it.  Both C<bin/new_config>, resolving a substitutable
dependency on this interface, and L<Provisioner::Recipe::letsencrypt>, rendering
the hook, ask this one question rather than each answering it -- which is how
they came to disagree before.

=cut

sub implementation_for {
    my ( $class, %opts ) = @_;

    my $domain   = $opts{domain};
    my $reserved = Provisioner::Utils::tld_of($domain);
    $reserved = ( defined $reserved && any { $_ eq $reserved } @RESERVED_TLDS ) ? $reserved : undef;

    die "implementation_for was not told what $domain is configured with; pass configured => the domain's recipes.\n"
      unless ref $opts{configured} eq 'HASH';

    my $server = $opts{host} // $domain;

    # Both candidates asked the same way and of the same places: the domain's
    # own configuration and the machine's, since a domain layered onto another
    # is served by what that guest runs.
    my @where     = ( $opts{configured}, $opts{host_configured} );
    my $local     = ( $reserved || _configures( $LOCAL_IMPLEMENTATION, @where ) ) ? 1 : 0;
    my $registrar = _configures( 'registrar', @where );

    my $stated = $opts{ $class->tiebreaker_key };
    if ( defined $stated && length $stated ) {
        die "$domain is under .$reserved, which RFC 2606 and RFC 6761 reserve, so no public registrar can hold a zone for it -- dns_preference: registrar names a provider that could never answer its challenge.  The guest serves this name itself; drop the preference.\n"
          if $stated eq 'registrar' && $reserved;

        die "$domain asks for dns_preference: $LOCAL_IMPLEMENTATION, but $server is configured with no $LOCAL_IMPLEMENTATION recipe, so nothing on the guest could answer its dns-01 challenge.  Add $LOCAL_IMPLEMENTATION, or name the registrar that holds the zone.\n"
          if $stated eq $LOCAL_IMPLEMENTATION && !$local;

        return $stated;
    }

    # No tie to break under a reserved TLD, whatever credentials a domain
    # inherited: a public registrar is not a provider that could serve one, so
    # there is only ever the one candidate.
    return $LOCAL_IMPLEMENTATION if $reserved;

    return 'registrar'           if $registrar && !$local;
    return $LOCAL_IMPLEMENTATION if $local     && !$registrar;

    die "$domain is configured with both a DNS server of its own and registrar credentials, and either could answer its dns-01 challenge.  Set dns_preference to '$LOCAL_IMPLEMENTATION' or 'registrar' to say which one holds the zone this name is served from.\n"
      if $local && $registrar;

    die "$domain has no DNS provider that could answer a dns-01 challenge: set registrar credentials for its zone, or add the $LOCAL_IMPLEMENTATION recipe so the guest serves the zone itself.\n";
}

# Whether a recipe appears in any of the configurations handed over: the
# domain's, and the machine's where it is layered onto another.
#
# Handed rather than fetched.  Asking Provisioner::Cookbook would answer about
# the configuration the environment names, and a resolver that goes looking
# cannot be told which one it is being asked about -- bin/new_config takes
# --recipes, so the two can in principle be different files.  Every real
# invocation points both at one directory, scratch guests included, so this is
# not a fault anybody has hit; it is a question with no safe default, and the
# caller is the only one that knows the answer.
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
