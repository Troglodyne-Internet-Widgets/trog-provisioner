package Provisioner::Recipe::letsencrypt;

#ABSTRACT: Issue and install TLS certificates via dehydrated and DNS DCV.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use List::Util qw{uniq};

use Provisioner::Cookbook();
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
fetch reads the guest as root, so the salvage needs nothing wider.

The private key of each certificate is C<0640 root:ssl-cert>.  Some services
read the key after they drop root.  slapd is one of them, and the ldap recipe
puts its account in C<ssl-cert>.  That group is the convention of Debian for
this, and it holds service accounts only, not the admin account.  The account
key stays C<0600 root>, because no service reads it.

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

=head2 Which services learn of a new certificate

A service reads the certificate when it starts or reloads, and not when the file
changes.  So each recipe on the guest names the units that read it, in
C<certificate_readers>, and this recipe reloads them twice: in C<get_cert>,
after it links the certificate into F</etc/ssl>, and in the C<deploy_cert> hook,
after the nightly renewal writes a new one.  A unit that is not running stays
as it is.

=head2 Which CA issues, and how a reserved TLD gets one at all

C<ca> is a dehydrated preset name or the URL of a directory.  Its default
depends on the domain, not on one value.  A name under a public suffix gets the
public Let's Encrypt directory.  A name under a TLD that RFC 2606 and RFC 6761
reserve gets the CA of this fleet.  These TLDs are C<.test>, C<.example>,
C<.invalid> and C<.localhost>.  No public CA issues for them.  Let's Encrypt
refuses such an order with C<rejectedIdentifier>, I<Domain name does not end
with a valid public suffix (TLD)>.

This default pulls in L<Provisioner::Recipe::acmeca>, which serves the CA.  A
guest under a reserved TLD holds its own zone unless it names an authority, so
L<Provisioner::Recipe::registrar> pulls in L<Provisioner::Recipe::pdns>, which
answers the C<dns-01> challenge on loopback.  pdns makes its own C<api_key>, and
lexicon gets the same key from it.  See L<Provisioner::Recipe::pdns/api_key_for>.

A guest whose C<registrar> names an C<authority> is different.  The authority
holds the zone of the guest, so lexicon writes the challenge there, and the
guest gets no pdns.  Where the authority is under the same reserved TLD, the
default is the CA on the authority, which reads the challenge from its own
zone.  So the guest also gets no acmeca.  See
L<Provisioner::Recipe::acmeca/fleet_ca_of>.

=head2 Which server answers the challenge

L<Provisioner::Recipe::registrar> says which server holds the zone of the
domain, and gives lexicon its credentials.  This recipe writes the challenge
there.  See L<Provisioner::Recipe::registrar/authority_of>.

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

# 1 if the CA of this domain is ours by default and not by name, and 0 if not.
# It reads the raw options, where an absent ca is still absent, because
# required_recipes runs before validation.
my sub auto_ca (%opts) {
    return ( !defined $opts{ca} && Provisioner::Utils::reserved_tld( $opts{domain} ) ) ? 1 : 0;
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
            hostnames => {
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'The names under the domain that the recipes on it serve.  Each recipe hands its own over: see served_names in Provisioner::Recipe.  Not for an operator to write; configure an alias in the aliases of _global.',
            },
        },
    );
}

sub enrich {
    my ( $self, %params ) = @_;

    die "prefer_local_dns is gone.  The registrar recipe says which server answers the challenge of this domain: the pdns of the guest where it runs one, or else the authority or the registrar that the registrar block names.\n"
      if exists $params{prefer_local_dns};

    # Nothing reads registrar credentials in _global.  Refuse them, because the
    # domain otherwise resolves to no provider or to the guest without a word.
    die "registrar credentials belong to the registrar recipe now, not to _global, so nothing reads the ones set for $params{domain}.  Move the registrar block out of _base._global and into _base, where it configures Provisioner::Recipe::registrar for every domain that inherits it.\n"
      if ref $params{registrar} eq 'HASH' && !exists( Provisioner::Cookbook->domain_config( $params{domain} )->{registrar} );

    # The default CA depends on the domain: see L</Which CA issues, and how a
    # reserved TLD gets one at all>.
    if ( auto_ca(%params) ) {

        # acmeca says where it answers, and does not set its port, because
        # resolve_conflict dies on a second value for a field that the operator
        # set.
        $params{ca} = Provisioner::Cookbook->load('acmeca')->directory_for( $params{domain} );
    }
    $params{ca} //= $DEFAULT_CA;

    # The same name and structure that the shortcut renders from, so the two
    # exports of one credential cannot drift apart.
    my $registrar = Provisioner::Cookbook->load('registrar');
    $params{lexicon} = { $registrar->credentials_for(%params) };

    # The socket of the server on the guest, which get_cert waits for before it
    # asks for a challenge.  An authority is reached at a URL, not a socket.
    my %extra = map { $_->{key} => $_->{value} } @{ $params{lexicon}{extra} // [] };
    $params{lexicon_socket} = $registrar->serves_itself( $params{domain} ) ? $extra{PDNS_SERVER} // q{} : q{};
    $params{domain_aliases} = [ $self->domain_aliases(%params) ];

    # Each recipe on the guest names the units that read the certificate.  See
    # certificate_readers in Provisioner::Recipe.
    $params{certificate_readers} = [ uniq map { Provisioner::Cookbook->load($_)->certificate_readers(%params) } grep { Provisioner::Cookbook->has($_) } @{ $params{modules} // [] } ];

    return %params;
}

=head2 %restores = $recipe->restores(%opts)

The certificates, so that a rebuild does not request them again against the
rate limit, and the ACME account, but only for a CA that outlives the guest.

A rebuild of the guest also rebuilds the CA when C<ca> is not set and the
domain is under a reserved TLD, or when C<ca> is a URL whose host is
C<localhost> or C<127.0.0.1>.  acmeca runs on the guest, on loopback, or on the
authority of the guest, which a rebuild of the authority rebuilds.  Each
provision starts it with an empty database and a new intermediate.  So it does
not know an account that it issued before, and every order on that account
returns C<accountDoesNotExist>.

Every other CA outlives the guest.  That includes a CA that is neither Let's
Encrypt nor ours, such as C<buypass>, C<zerossl>, or an internal CA on another
machine.  An account with one of them is the identity of this installation with
a third party, and the recipe keeps it on purpose.  If the recipe drops it, the
rebuild registers again for nothing.  With Let's Encrypt, that also breaks their
terms.

=cut

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    my %restores = ( "/var/lib/dehydrated/certs/$domain" => { from => "$install_dir/$domain/.letsencrypt/var-certs/$domain", owner => 'root:root' } );

    return %restores if !defined $opts{ca} && Provisioner::Utils::reserved_tld($domain);

    my $host = defined $opts{ca} ? ( Provisioner::Utils::host_of( $opts{ca} ) // q{} ) : q{};
    return %restores if $host eq 'localhost' || $host eq '127.0.0.1';

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
preset, unless the default CA of the domain is the CA of its authority.

=item * C<registrar>, which holds the zone of this domain, or says which server
does.

=item * C<lexicon>, which writes the challenge.

=back

The recipe gives acmeca no options, because the configuration of a CA is its own
business.  The acmeca edge exists for the order.  bin/new_config puts a required
recipe after the last recipe that requires it and before the postrun.  The
fetcher that this recipe queues asks the CA for a certificate during the
postrun.  So the dependency makes sure that the CA answers by then.  It does not
depend on where two recipes happen to sit in a list.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my $auto     = auto_ca(%opts) && !defined Provisioner::Cookbook->load('acmeca')->fleet_ca_of( $opts{domain} );
    my @required = ( $auto || ( defined $opts{ca} && $opts{ca} ne $DEFAULT_CA ) ) ? ( acmeca => sub { return () } ) : ();
    push( @required, registrar => sub { return () }, lexicon => sub { return () } );

    return @required;
}

sub tests {
    return qw{letsencrypt.tt};
}

1;
