package Provisioner::DNSRecipe;

#ABSTRACT: Base class for a recipe that can answer a dns-01 challenge for a domain.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use Scalar::Util();

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

# What a guest gets when nothing has said otherwise and more than one could
# answer.  The local server: it is the one this fleet builds, and the one a
# reserved TLD has no alternative to.
our $DEFAULT_IMPLEMENTATION = 'pdns';

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

=head2 $name = $recipe->default_implementation()

Which implementation a guest uses when more than one could answer and nothing
has said which.  C<pdns>, the server this fleet runs itself.

=cut

sub default_implementation { return $DEFAULT_IMPLEMENTATION }

sub _unanswered {
    my ( $self, $what ) = @_;

    my $recipe = Scalar::Util::blessed($self) || $self;
    $recipe =~ s/\AProvisioner::Recipe::(?:\w+::)?//;

    die "The $recipe recipe does not say what its $what is.\n" . "Every recipe that can answer a dns-01 challenge has to answer that before\n" . "anything can write a record through it; see perldoc Provisioner::DNSRecipe.\n";
}

1;
