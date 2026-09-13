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

B<Only where that DNS server is actually present.>  This recipe can be rendered
without the depsolver that puts pdns in C<modules> -- F<t/recipes.t> and
F<bin/recipes> both do it -- and a guest under a reserved TLD with no local DNS
cannot answer a challenge from anybody.  There the public CA stays: nothing can
issue for the name either way, and the failure belongs where it already was
rather than becoming a fatal in C<enrich>.

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
        'ssl.lexicon.sh.tt'           => 'lexicon.sh',
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

# Whether this domain wants a CA of ours built for it: it named something other
# than the public preset, or it is under a TLD no public CA will issue for.
# Read from raw options, because required_recipes runs before validation, where
# an absent ca is still absent rather than defaulted.
sub _our_ca {
    my (%opts) = @_;

    return 1 if defined $opts{ca} && $opts{ca} ne $DEFAULT_CA;
    return ( !defined $opts{ca} && _reserved_tld( $opts{domain} ) ) ? 1 : 0;
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

    my $configured = Provisioner::Cookbook->domain_config($domain)->{pdns}{api_key};
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
            registrar => {
                type       => 'object',
                properties => {
                    type => { type => "string" },
                    user => { type => "string" },
                    key  => { type => "string" },
                },
            },

            #TODO If this isn't true, registrar is required.
            # Not sure how to encode that in openapi spec here.
            prefer_local_dns       => { type => 'boolean', default => 0 },
            local_dns_access_token => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %params ) = @_;

    # The recipes able to answer a dns-01 challenge on this guest.  Asked once:
    # the CA this domain defaults to depends on it, and so does the guard below.
    my %answers_dns = map { $_ => 1 } qw{pdns};
    my $has_dns     = any { $answers_dns{$_} } @{ $params{modules} // [] };

    # Which CA, and why it turns on the domain and on pdns being here: see
    # L</Which CA issues, and how a reserved TLD gets one at all>.
    if ( !defined $params{ca} && $has_dns && _reserved_tld( $params{domain} ) ) {
        $params{ca}               = _directory_url( $params{domain} );
        $params{prefer_local_dns} = 1;

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
    $params{ca} //= $DEFAULT_CA;

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
    $params{lexicon_opts} = $params{prefer_local_dns} ? '--resolve-zone-name' : q{};

    # If the user instructs that we ought to use the local DNS server
    # instead of the global registrar info, let's do that.
    # Also make sure that we have the "right stuff" setup otherwise.
    if ( $params{prefer_local_dns} ) {
        die "Must have at least one dns provider recipe used" unless $has_dns;
        $params{registrar} = {
            type => 'powerdns',
            user => '',
            key  => $params{local_dns_access_token},
        };

        #XXX pretty dopey that the var is POWERDNS_PDNS_SERVER, but load bearing at this point
        $params{extra_lexicon_vars} = [ { key => 'PDNS_SERVER', value => '/var/spool/powerdns/api.sock' } ];
    }
    else {
        die "Must set registrar info in _global section of config" unless exists $params{registrar} && ( ref( $params{registrar} ) eq 'HASH' );
    }
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

    # Before validation, so an absent ca is still absent here rather than
    # defaulted -- which is what tells a domain that chose the public CA from one
    # that said nothing and is under a TLD the public CA cannot issue for.
    my $auto     = !defined $opts{ca} && _reserved_tld( $opts{domain} );
    my @required = _our_ca(%opts) ? ( acmeca => sub { return () } ) : ();

    # acmeca requires pdns itself and hands it nothing, so the api_key it needs
    # would have nowhere to come from on a guest nobody configured by hand.  Only
    # when this recipe is the reason pdns is there, and only when the operator
    # set no key of their own: handing one they had also written is the conflict
    # resolve_conflict dies on.
    if ($auto) {

        # The machine's domain rather than this one's: a single pdns serves the
        # whole guest, so a domain layered onto another has to hand it the key
        # that server is already running with.  See dns_host_domain, which
        # bin/new_config sets from depends_on.
        my $server     = $opts{dns_host_domain} // $opts{domain};
        my $configured = Provisioner::Cookbook->domain_config($server)->{pdns}{api_key};
        unless ( defined $configured && length $configured ) {
            my $token = _dns_token($server);
            push( @required, pdns => sub { return ( api_key => $token ) } );
        }
    }

    return ( @required, $self->SUPER::required_recipes(%opts) );
}

sub tests {
    return qw{letsencrypt.tt};
}

1;
