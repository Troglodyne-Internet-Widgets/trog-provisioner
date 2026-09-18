package Provisioner::Recipe::pdns;

#ABSTRACT: Set up the PowerDNS resolver and install DNS records.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::DNSRecipe};

=head1 Provisioner::Recipe::pdns

=head2 SYNOPSIS

    somedomain:
        pdns:
            extra_records: zonefile_fragment.txt

=head2 DESCRIPTION

Set up powerdns resolver, and install a sensible set of records for your chosen recipe(s).

See templates/files/pdns.zone.tt for what is set up.

The idea here is to allow simple DNS delegation of subdomains to provisioned machines.

Uses the sqlite backend.

Appends arbitrary records specified as extra_records: plain text files, each a zonefile fragment.  Relative to the datadir if not absolute path.

Sets up the recursor in the event you want to point your resolver at it for fast resolves and to mitigate DNS rate-limiting by RBLs.

=cut

use Text::Xslate;
use Net::IP;
use File::Slurper;
use Crypt::PRNG();

use Provisioner::Cookbook();

# Where pdns binds its API, inside the chroot.  Named here because this recipe
# is what puts it there: the unit, the configuration and every client that talks
# to it read this one value.
our $API_SOCKET = '/var/spool/powerdns/api.sock';

sub rate_limits {

    # A resolver asks over UDP and asks often; a recursor in front of this one
    # asks on behalf of everybody behind it.  Set high enough that only a
    # reflection flood reaches it.
    #
    # Both protocols, and udp is the one that matters: it is what a resolver
    # asks over and what a reflection flood arrives on.  tcp is named too
    # because a zone transfer and any answer too large for a datagram go that
    # way, and an unlimited half is the half that gets used.
    return ( 53 => 4096, '53/udp' => 4096 );
}

=head2 %required = $recipe->required_recipes(%opts)

Adds C<nostubresolver> and C<lexicon>.

L<Provisioner::Recipe::lexicon> is the client anything writes a record into this
server's zone with, and what the patches this recipe used to carry are patches
to.

A guest running this server is the only thing that answers for its own zone, and
the stub in front of it does not: lexicon walks the zone through the system
resolver for C<--resolve-zone-name>, and step-ca validates dns-01 through it, so
a guest left on the stub resolves its own name nowhere.

L<Provisioner::Recipe::letsencrypt> asks for the same recipe when it is this
server that answers its challenge.  Asking here as well is what covers a guest
serving a zone without one.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;
    return ( nostubresolver => sub { return () }, lexicon => sub { return () }, $self->SUPER::required_recipes(%opts) );
}

sub args {
    return (
        type       => 'object',
        properties => {
            api_key => {
                type        => 'string',
                description =>
                  'The credential everything on this guest presents to talk to the API on its loopback socket -- lexicon writing an _acme-challenge record, synczones reading the zone back.  Made here when nobody sets one, because it is a secret nobody chose rather than a decision an operator has to make; a secret: reference is how you set one deliberately.  It belongs to the server, so a domain layered onto another guest presents that machine key rather than one of its own.',
            },
            extra_records => { type => 'string' },

            # Whoever holds the public zone this guest syncs up to, as the
            # registrar recipe's own three fields.  The operator's to set: this
            # guest's own credentials go under lexicon, and putting them here
            # would have it name itself as its own upstream.
            registrar => {
                type       => 'object',
                properties => {
                    type => { type => 'string', description => 'The lexicon provider holding the zone, spelled as the registrar recipe spells it.' },
                    user => { type => 'string', description => 'The username that provider authenticates with.' },
                    key  => { type => 'string', description => 'The token or password for it.' },
                },
            },

            # Which repo.powerdns.com train to install from.  This asked for
            # auth-master, which is the development branch: guests came up with
            # 5.1.0~alpha1+master.380 on them.  A release train, so an upgrade
            # is a decision rather than whatever landed on master that morning.
            # auth-51, not auth-49: the API is configured on a unix socket --
            # deliberately, there is a lexicon patch in this repository for
            # talking to one -- and webserver-address only accepts a socket path
            # from PowerDNS 5.0.0 onwards.  On 4.9 pdns_server refuses to start
            # at all, with "Unable to convert presentation address".  This
            # recipe used auth-master, which was 5.1.0~alpha and had the
            # feature; auth-51 is the released form of the same thing.
            repo_branch => {
                type    => 'string', default => 'auth-51',
                pattern => '^auth-[0-9]+$'
            },

            # Zones to forward to another resolver, as zone => address.
            forward_zones => { type => 'object', default => {} },
        },
    );
}

=head2 %credentials = $recipe->lexicon_credentials(%opts)

The API on the loopback socket, which is how anything on this guest writes a
record into the zone this server holds.  See L<Provisioner::DNSRecipe>.

C<--resolve-zone-name> because lexicon reduces a name to its registrable form
with tldextract before asking for a zone, and a reserved TLD is not a public
suffix -- so it asked for the zone "test" and got a 404.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    # Settled here rather than taken on trust.  enrich has put the key in opts
    # by the time this recipe renders its own templates, but letsencrypt asks
    # this as a class method to render its hook -- nothing has enriched
    # anything on that path, and taking $opts{api_key} on faith rendered an
    # empty token into the file dehydrated executes.
    my $key =
      length( $opts{api_key} // q{} )
      ? $opts{api_key}
      : $self->api_key_for( $opts{domain} );

    return (
        type  => 'powerdns',
        user  => q{},
        key   => $key,
        opts  => '--resolve-zone-name',
        extra => [ { key => 'PDNS_SERVER', value => $API_SOCKET } ],
    );
}

=head2 $key = $recipe->api_key_for($domain)

The credential this server runs with, for the guest C<$domain> holds it on.

An operator who set one owns it.  Otherwise it is made here -- once per server,
because the API config, the dehydrated hook and the lexicon shortcut all have to
present the same value, and a second one is a 401 rather than a warning.  The
server belongs to a guest rather than to a domain, so a domain layered onto
another is answered with the key that machine's server already runs with -- which
this works out from L<Provisioner::Cookbook/host_of> rather than being told.

=cut

sub api_key_for {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;

    my $configured = Provisioner::Cookbook->domain_config($server)->{ $self->recipe_name }{api_key};
    return $configured if defined $configured && length $configured;

    state %made;
    return $made{ $server // q{} } //= Crypt::PRNG::random_bytes_hex(32);
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Minted here rather than by whoever needed it first.  It used to be
    # letsencrypt's, under a second name in _global, which meant the credential
    # for this API reached every recipe on the guest and was owned by none of
    # them.
    $opts{api_key} = $self->api_key_for( $opts{domain} )
      unless length( $opts{api_key} // q{} );

    my $extras = $opts{extra_records} // '';
    if ($extras) {
        my $is_abs_path = index( $extras, '/' ) == 0;
        $extras = "$opts{data_source}/$opts{domain}/$extras" unless $is_abs_path;
        $opts{extra_records} = File::Slurper::read_text($extras);
    }

    $opts{serial} = time;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'pdns.zone.tt'         => 'zonefile',
        'pdns.domain.tt'       => 'pdns-domain.conf',
        'pdns.global.tt'       => 'pdns-global.conf',
        'pdns.recursor.tt'     => 'pdns-recursor-domain.conf',
        'pdns.recursor.lua.tt' => 'pdns-recursor-domain.lua',
        'pdns.rsyslog.tt'      => '10-powerdns.conf',
        'pdns.api.tt'          => 'pdns-api.conf',
        'pdns.synczones.tt'    => 'synczones.conf',
    );
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # The whole spool, because the chroot is what pdns opens everything relative
    # to.  0775 because the chroot needs the group in.
    return ( '/var/spool/powerdns' => { from => "$install_dir/$domain/pdns", owner => 'pdns:pdns', mode => '0775' } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The sqlite database holding every zone record the guest answers for,
        # which after provisioning is not what the zonefile said: lexicon writes
        # the DCV records into it, and so does anybody adding a record by hand.
        # A rebuilt guest that started from the zonefile again would answer with
        # the handful of records this recipe knows about and nothing else.
        #
        # The whole spool comes down, not just zones.db, because the chroot is
        # what pdns opens everything relative to.  The global fragment puts it
        # back -- one zones.db serves every domain on the guest, so restoring it
        # is a fact about the machine rather than about a domain, and it has to
        # happen before the schema is applied or there would already be a
        # database in the way.
        #
        # Which leaves one hole worth knowing about: the global half runs for
        # whichever domain reaches it first, so a guest hosting several and
        # rebuilt starting from a domain that never had a previous guest gets an
        # empty database, and the other salvages sit unrestored in their domain
        # directories.  The guest test says so when it happens.
        '/var/spool/powerdns/' => 'pdns/',
    );
}

sub formatters {
    my ($class) = shift;
    return (
        reverse_ip => Text::Xslate::html_builder(
            sub {
                my $ip = shift;
                return Net::IP->new($ip)->reverse_ip();
            }
        ),
        email_for_dns => Text::Xslate::html_builder(
            sub {
                my $email = shift;
                $email =~ tr/@/./;
                return $email;
            }
        ),
    );
}

sub tests {
    return qw{pdns.tt};
}

=head2 @hosts = $recipe->fetch_hosts()

The PowerDNS apt repository, which this recipe adds and installs from.

=cut

sub fetch_hosts {
    return qw{repo.powerdns.com};
}

=head2 @classes = $recipe->cache_classes()

=cut

sub cache_classes {
    my ($self) = @_;
    return $self->apt_repo_classes('repo.powerdns.com');
}

1;
