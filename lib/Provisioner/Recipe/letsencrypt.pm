package Provisioner::Recipe::letsencrypt;

#ABSTRACT: Issue and install TLS certificates via dehydrated and DNS DCV.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

use Crypt::PRNG();

use Provisioner::Cookbook();
use Provisioner::DNSRecipe();
use Provisioner::Utils();

=head1 Provisioner::Recipe::letsencrypt

=head2 SYNOPSIS

    somedomain:
        letsencrypt:

=head2 DESCRIPTION

Configures lexicon to be able to update TXT records for your domain with your registrar so you can do DNS DCV.

Configures dehydrated to use lexicon to do DNS DCV w/ lexicon.

Sets up convenience scripts in /opt/lexicon per domain to run lexicon manually:

    /opt/lexicon/my.domain.name list TXT

Also stashes a local copy of any provisioned certs so you don't violate ToS or get rate-limited from repeated redeploys of systems.
Requires that the user running new_config has a key authorized as the admin user on the remote host.

=head2 What the salvage needs to be able to read

C<remote_files> names the two certificate directories and the account
directory, and the certificates in them are no use on their own. A guest rebuilt
with certificates it has no keys for issues again from scratch, which is what the
salvage exists to avoid: it spends Let's Encrypt rate limit, and if the account
key went missing with them it spends the registration as well -- the old
certificates stay valid, but nothing can revoke them and the guest is a stranger
to the CA again.

dehydrated writes every private key it makes C<0600 root>, and the guest leaves
them readable by the admin account -- from when the fetch ran as that user and
would otherwise return an empty directory and say nothing anybody reads.  The
fetch reads the guest as root now and no longer needs that; taking it out is
issue #98, and it is a private key in every backup until somebody does.  It is
done in two places, and it has to be both:
C<get_cert> after the provision, and the C<exit_hook> in this domain's dehydrated
hook after B<every> dehydrated run, because the nightly renewal writes a fresh
private key and never goes near C<get_cert>.

What that leaves on the guest: certificates world readable, since they are
public; private keys and the account key C<0640 root:E<lt>adminE<gt>>, which is
the least that a fetch by that account can still read. The consequence to know
about is the other end of the wire -- the keys land in the provisioner's data
directory and in whatever backs it up, so that directory holds this domain's TLS
private keys.

The account key goes back in the global fragment rather than this recipe's own,
because the global one runs first and ends with C<dehydrated --register>: by the
time the per-domain fragment runs there is an account in the destination
already, and C<restore_state> will not write over one.

That is the public CA's arrangement.  An account issued by a CA this guest runs
itself is not put back at all -- see C<restores>.

=head2 Which CA issues, and how a reserved TLD gets one at all

C<ca> is a dehydrated preset name or the URL of a directory, and it defaults by
the domain rather than to one value.  A name under a public suffix gets the
public Let's Encrypt directory, which is what it has always been.  A name under
a TLD RFC 2606 and RFC 6761 reserve -- C<.test>, C<.example>, C<.invalid>,
C<.localhost> -- gets this fleet's own, because no public CA will issue for one:
Let's Encrypt answers such an order with C<rejectedIdentifier>, I<Domain name
does not end with a valid public suffix (TLD)>, and every provision of a
C<.test> guest ended on it with a red makefile.

Defaulting there pulls in L<Provisioner::Recipe::acmeca>, which serves the CA,
and through it L<Provisioner::Recipe::pdns>, which answers the C<dns-01>
challenge on loopback.  pdns needs an C<api_key> that nobody configured, so this
supplies one -- made once per domain and given to both, because lexicon
authenticates with the same value pdns is configured with.  An operator who set
an C<api_key> of their own keeps it and is handed nothing, since handing a
second value for a field they had already written is the collision
C<resolve_conflict> dies on.

B<And it is asked of the domain, not of the module list.>  A reserved TLD is
served by the guest's own pdns, which this recipe requires through acmeca -- so
that server is there whenever the name needs it, and asking whether it was
present was asking a question with only one answer.  It was asked of C<modules>,
which the depsolver adds to between C<required_recipes> and C<enrich>, so the
two came to different answers about the same domain.

=head2 Which provider answers the challenge

C<dns_preference> names it -- C<pdns> for the server this fleet runs on the
guest, C<registrar> for whoever holds the domain's public zone -- and it is a
tiebreaker rather than a setting.  Nothing needs it in the ordinary case: a name
under a reserved TLD is always served locally, since no public registrar can
hold a zone for one, and a domain configured with only one of the two uses that
one.

It earns its keep where a guest has both, which is a public name whose zone this
fleet also serves.  The credentials inherited from C<_global> and the local
server are each able to answer, they answer differently, and choosing on the
domain's behalf would be a guess -- so a domain that configures both and names
neither is refused rather than resolved.

Two configurations are refused outright.  C<registrar> under a reserved TLD
names a provider that could never answer for the name, and C<pdns> where no such
server is configured names one that is not there.

=head2 What a guest served by our own CA can be issued for

Names inside its own zone, and nothing else.

L<Provisioner::Recipe::pdns> builds one zone per guest -- the domain itself --
so C<www.> and C<mail.> sit inside it and are fine, while an alias outside it
has nowhere for lexicon to write C<_acme-challenge> and no local server
authoritative for it.  A cross-TLD alias is the visible case, but the rule is
the zone and not the TLD: C<test.troglodyne.net> as an alias of
C<dev.troglodyne.net> is out of zone as well.

The authority is not what limits this.  C<nameConstraints> takes a list, so one
intermediate can permit several TLDs and leaves under each of them verify --
measured, rather than assumed.  What cannot be arranged is the challenge.

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

# dehydrated's own preset for the public Let's Encrypt directory, and what a
# domain gets when it asks for no particular CA.
our $DEFAULT_CA = 'letsencrypt';

# RFC 2606 and RFC 6761 keep these for documentation, testing and private use,
# which is exactly why no public CA will issue for a name under one: it is not a
# public suffix, so nobody can demonstrate control of it.  A guest under one of
# these gets its certificate from the fleet's own CA or it gets none.
our @RESERVED_TLDS = qw{test example invalid localhost};

# The TLD when it is one only our own CA can issue for, and nothing otherwise.
sub _reserved_tld {
    my ($domain) = @_;

    my $tld = Provisioner::Utils::tld_of($domain) or return;

    return ( any { $_ eq $tld } @RESERVED_TLDS ) ? $tld : ();
}

# Whether this domain's CA is one of ours by default rather than by name: it is
# under a TLD no public CA will issue for.  Read from raw options, because
# required_recipes runs before validation, where an absent ca is still absent
# rather than defaulted -- which is what tells a domain that chose the public CA
# from one that said nothing.
sub _auto_ca {
    my (%opts) = @_;

    return ( !defined $opts{ca} && _reserved_tld( $opts{domain} ) ) ? 1 : 0;
}

# Whether this domain wants a CA of ours built for it: it named something other
# than the public preset, or it is under a TLD no public CA will issue for.
sub _our_ca {
    my (%opts) = @_;

    return 1 if defined $opts{ca} && $opts{ca} ne $DEFAULT_CA;
    return _auto_ca(%opts);
}

# Which DNS provider writes this domain's _acme-challenge record: 'pdns' for the
# server this fleet runs on the guest, 'registrar' for whoever holds the public
# zone.  Dies rather than returning undef; every caller needs an answer.
#
# Asked of the domain's configuration -- its TLD, its tiebreaker, and what it is
# configured with -- rather than of the module list, which is not the same list
# at every point this could be asked: bin/new_config's depsolver appends the
# pdns this recipe pulls in through acmeca, so a reserved TLD reads as having no
# local DNS server before that happens and as having one afterwards.  Deriving
# the provider from that list made the answer depend on when it was put.
# The recipe implementing a provider, as a class.  Loaded rather than
# instantiated: lexicon_credentials reads its arguments and nothing on the
# object, and constructing one would want template_dirs that enrich has no
# business knowing about.
# Whether a domain is configured with a recipe, asked of the configuration
# rather than of the module list -- which is not the same list before and after
# the depsolver has run.  The machine's domain as well as this one's, because a
# domain layered onto another is served by what that guest runs.
sub _configures {
    my ( $domain, $recipe, $host ) = @_;

    foreach my $where ( grep { defined } ( $domain, $host ) ) {
        my $conf = Provisioner::Cookbook->domain_config($where) // {};
        return 1 if exists $conf->{$recipe};
    }

    return 0;
}

# What to ask an implementation its credentials with: the configuration of that
# recipe for this domain, which is its own block and not this one's.  pdns is
# handed the token as well, because this recipe is what mints one for a guest
# whose operator configured no key of their own.
sub _provider_config {
    my ( $provider, %params ) = @_;

    my $server = $params{dns_host_domain} // $params{domain};
    my $conf = Provisioner::Cookbook->domain_config( $params{domain} )->{$provider} // Provisioner::Cookbook->domain_config($server)->{$provider} // {};

    return ( %{$conf}, domain => $params{domain}, api_key => $conf->{api_key} // $params{local_dns_access_token} );
}

sub _implementation {
    my ($provider) = @_;

    my $class = eval { Provisioner::Cookbook->load($provider) };
    die "$provider is not a recipe this installation has, so nothing can answer a dns-01 challenge through it.\n" unless $class;
    die "$provider cannot answer a dns-01 challenge: it is not a Provisioner::DNSRecipe.\n"                       unless $class->isa('Provisioner::DNSRecipe');

    return $class;
}

sub _dns_provider {
    my (%opts) = @_;

    my $reserved = _reserved_tld( $opts{domain} );
    my $server   = $opts{dns_host_domain} // $opts{domain};

    # Both candidates asked the same way and of the same places: the domain's
    # own configuration and the machine's, since a domain layered onto another
    # is served by what that guest runs.  They were asked differently once --
    # the local server of the machine alone, the registrar of both -- so a
    # domain carrying its own DNS server on a host without one was local to half
    # of this decision and not to the other.
    my $local     = ( $reserved || _configures( $opts{domain}, Provisioner::DNSRecipe->local_implementation(), $server ) ) ? 1 : 0;
    my $registrar = _configures( $opts{domain}, 'registrar', $server );

    my $stated = $opts{dns_preference};
    if ( defined $stated && length $stated ) {
        die "$opts{domain} is under .$reserved, which RFC 2606 and RFC 6761 reserve, so no public registrar can hold a zone for it -- dns_preference: registrar names a provider that could never answer its challenge.  The guest serves this name itself; drop the preference.\n"
          if $stated eq 'registrar' && $reserved;

        die "$opts{domain} asks for dns_preference: pdns, but $server is configured with no pdns recipe, so nothing on the guest could answer its dns-01 challenge.  Add pdns, or name the registrar that holds the zone.\n"
          if $stated eq 'pdns' && !$local;

        return $stated;
    }

    # No tie to break under a reserved TLD, whatever credentials reached this
    # recipe from _global: a public registrar is not a provider that could serve
    # one, so there is only ever the one candidate.
    return 'pdns' if $reserved;

    return 'registrar' if $registrar && !$local;
    return 'pdns'      if $local     && !$registrar;

    die "$opts{domain} is configured with both a DNS server of its own and registrar credentials, and either could answer its dns-01 challenge.  Set dns_preference to 'pdns' or 'registrar' to say which one holds the zone this name is served from.\n"
      if $local && $registrar;

    die "$opts{domain} has no DNS provider that could answer a dns-01 challenge: set registrar credentials for its zone, or add the pdns recipe so the guest serves the zone itself.\n";
}

# Whether the CA issuing for this domain is rebuilt along with the guest, which
# is a narrower question than the one above and is asked about the ACME account.
#
# acmeca runs on the guest, on loopback, and comes back on every provision with
# an empty database and a freshly minted intermediate -- so an account it issued
# last time names somebody it has never heard of.  Any other CA outlives the
# guest, and that includes the ones that are neither Let's Encrypt nor ours:
# buypass, zerossl, an internal CA on another machine.  Their accounts are this
# installation's identity with a third party, kept deliberately, and discarding
# one is both a rebuild that re-registers for nothing and, with Let's Encrypt, a
# breach of their terms.
sub _ca_rebuilt_with_guest {
    my (%opts) = @_;

    return 1 if !defined $opts{ca} && _reserved_tld( $opts{domain} );
    return 0 unless defined $opts{ca};

    my $host = Provisioner::Utils::host_of( $opts{ca} ) // q{};

    return ( $host eq 'localhost' || $host eq '127.0.0.1' ) ? 1 : 0;
}

# What acmeca answers on for this domain.  Read rather than dictated: handing a
# port to a recipe the operator may also have configured is a conflict
# Provisioner::Recipe::resolve_conflict would die on, naming a field they had
# already set.
sub _directory_url {
    my ($domain) = @_;

    my $configured = Provisioner::Cookbook->domain_config($domain)->{acmeca}{port};
    my %args       = Provisioner::Cookbook->load('acmeca')->args();
    my $port       = $configured // $args{properties}{port}{default};

    return "https://localhost:$port/acme/trog/directory";
}

# The token lexicon authenticates to the local pdns with, which is that server's
# own api_key.  An operator who set one owns it; otherwise this is a secret
# nobody chose, so it is made here -- once per server, because pdns and every
# hook that talks to it have to be given the same one.  That is the domain the
# server belongs to, which is not this domain when this one is sharing another's
# machine: see dns_host_domain.
sub _dns_token {
    my ($domain) = @_;

    my $configured = Provisioner::Cookbook->domain_config($domain)->{ Provisioner::DNSRecipe->local_implementation() }{api_key};
    return $configured if defined $configured && length $configured;

    state %made;
    return $made{ $domain // q{} } //= Crypt::PRNG::random_bytes_hex(32);
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
            local_dns_access_token => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %params ) = @_;

    die "prefer_local_dns is now dns_preference, which names the recipe that answers this domain's challenge rather than asserting a boolean: 'pdns' for the server on the guest, 'registrar' for whoever holds the public zone.\n"
      if exists $params{prefer_local_dns};

    # registrar is its own recipe now, so credentials in _global reach nothing.
    # Refused rather than ignored: a domain whose zone a registrar holds would
    # otherwise resolve to no provider at all, or to the guest, and say nothing
    # about the credentials it had been given.
    die "registrar credentials belong to the registrar recipe now, not to _global, so nothing reads the ones set for $params{domain}.  Move the registrar block out of _base._global and into _base, where it configures Provisioner::Recipe::registrar for every domain that inherits it.\n"
      if ref $params{registrar} eq 'HASH' && !_configures( $params{domain}, 'registrar' );

    my $provider = _dns_provider(%params);

    # Which CA, and why it turns on the domain: see L</Which CA issues, and how a
    # reserved TLD gets one at all>.
    $params{ca} = _directory_url( $params{domain} ) if _auto_ca(%params);
    $params{ca} //= $DEFAULT_CA;

    # The provider the rest of the render is driven from, resolved rather than
    # declared: a domain that named no preference still has one.
    $params{dns_preference} = $provider;

    if ( $provider eq Provisioner::DNSRecipe->local_implementation() ) {

        # Tested for length rather than definedness: bin/new_config fills this
        # in from the domain's configured pdns, and does it before the depsolver
        # adds the one this recipe pulls in -- so on a guest that configured
        # none it arrives as the empty string rather than absent.  With //= it
        # stayed empty, the hook's [% IF registrar.key %] then rendered no
        # export at all, and lexicon died on "PowerDNS API key not defined
        # (auth_token)" after the order had already been placed.
        $params{local_dns_access_token} = _dns_token( $params{dns_host_domain} // $params{domain} )
          unless length( $params{local_dns_access_token} // q{} );
    }

    # What lexicon needs to reach whoever holds this zone, asked of the recipe
    # that holds it rather than assembled here.  This used to spell powerdns's
    # provider name, its empty username and its socket out in this block, which
    # is three facts about a server another recipe configures -- and the socket
    # was written down in two places.  See Provisioner::DNSRecipe.
    my %creds = _implementation($provider)->lexicon_credentials( _provider_config( $provider, %params ) );

    $params{registrar}          = { type => $creds{type}, user => $creds{user}, key => $creds{key} };
    $params{extra_lexicon_vars} = $creds{extra};

    # --resolve-zone-name rather than DELEGATED, and only for the local server.
    #
    # lexicon reduces a domain to its registrable name with tldextract before it
    # asks for a zone.  A reserved TLD is not a public suffix, so <guest>.test
    # collapsed to the zone "test", and DELEGATED was then composed back on top
    # of that -- asking pdns for zones/<guest>.test.test, which is a 404, on
    # every challenge.  Measured on a guest: with this flag lexicon finds the
    # real zone, writes the record, and the authoritative server serves it back.
    #
    # Not for a registrar, where the domain is the zone and tldextract is right
    # about it: the flag costs live DNS queries to work out something already
    # known.
    $params{lexicon_opts} = $creds{opts};

    return %params;
}

# /etc/dehydrated/certs is not among these.  dehydrated is configured with
# BASEDIR=/var/lib/dehydrated and writes its certificates under that, so the
# /etc one is made, chowned, and never written to -- salvaging it fetched an
# empty directory every run, and now that an empty salvage says so out loud it
# would say so every run about a directory that is empty on purpose.
sub restores {
    my ( $self, %opts ) = @_;
    my ( $install_dir, $domain, $admin ) = @opts{qw{install_dir domain admin_user}};

    # The certificates, which a rebuild would otherwise ask for again -- into the
    # rate limit.
    my %restores = ( "/var/lib/dehydrated/certs/$domain" => { from => "$install_dir/$domain/.letsencrypt/var-certs/$domain", owner => "root:$admin" } );

    # The ACME account is the identity the CA knows this guest by.  It is kept for
    # every CA that outlives the guest -- Let's Encrypt above all, where
    # re-registering each rebuild spends the registration and breaches their
    # terms -- and dropped only for one rebuilt alongside it, where a restored
    # account names somebody the new CA has never heard of and every order comes
    # back accountDoesNotExist.  Measured on a rebuilt guest: registering afresh
    # issued the certificate instead.
    return %restores if _ca_rebuilt_with_guest(%opts);

    return ( %restores, '/etc/dehydrated/accounts' => { from => "$install_dir/$domain/.letsencrypt/accounts", owner => "root:$admin" } );
}

sub remote_files {
    return (
        '/var/lib/dehydrated/certs/' => '.letsencrypt/var-certs',
        '/etc/dehydrated/accounts/'  => '.letsencrypt/accounts',
    );
}

=head2 %required = $recipe->required_recipes(%opts)

The CA, when this domain names one of the fleet's own rather than a public
preset.  Nothing is handed to it: what a CA is configured with is its own
business, and the edge exists for the ordering rather than for the options.

That ordering is the whole point.  bin/new_config puts a required recipe after
the last recipe that required it and before the postrun, and the fetcher this
recipe queues asks the CA for a certificate during the postrun -- so declaring
the dependency is what makes the CA answering by then a property of the build
rather than a coincidence of where two recipes happen to sit in a list.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my @required = _our_ca(%opts) ? ( acmeca => sub { return () } ) : ();

    # acmeca requires pdns itself and hands it nothing, so the api_key it needs
    # would have nowhere to come from on a guest nobody configured by hand.  Only
    # when this recipe is the reason pdns is there, and only when the operator
    # set no key of their own: handing one they had also written is the conflict
    # resolve_conflict dies on.
    if ( _auto_ca(%opts) ) {

        # The machine's domain rather than this one's: a single pdns serves the
        # whole guest, so a domain layered onto another has to hand it the key
        # that server is already running with.  See dns_host_domain, which
        # bin/new_config sets from depends_on.
        my $server     = $opts{dns_host_domain} // $opts{domain};
        my $local      = Provisioner::DNSRecipe->local_implementation();
        my $configured = Provisioner::Cookbook->domain_config($server)->{$local}{api_key};
        unless ( defined $configured && length $configured ) {
            my $token = _dns_token($server);
            push( @required, $local => sub { return ( api_key => $token ) } );
        }
    }

    # A guest that answers its own challenge has to be able to read back what it
    # just wrote.  lexicon walks the zone for --resolve-zone-name through the
    # system resolver, and step-ca validates dns-01 through it as well, so a
    # guest left on systemd's stub resolves its own name nowhere.  Measured on a
    # scratch guest: the walk fell all the way to the root, lexicon asked pdns
    # for zones/. and got a 404, and every challenge failed while dig
    # @127.0.0.1 answered for the zone perfectly well.  nostubresolver points
    # the resolver at the server on the guest; it is invisible on a fleet whose
    # _base gives every domain that recipe already.
    #
    # eval because this runs before validation: a domain configured with no
    # provider at all is enrich's to reject, and reporting it here as well would
    # race two messages for one fault.
    my $provider = eval { _dns_provider(%opts) } // q{};
    push( @required, nostubresolver => sub { return () } ) if $provider eq Provisioner::DNSRecipe->local_implementation();

    return ( @required, $self->SUPER::required_recipes(%opts) );
}

sub tests {
    return qw{letsencrypt.tt};
}

1;
