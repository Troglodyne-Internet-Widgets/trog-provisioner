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

Sets up the PowerDNS authoritative server and recursor, and installs a set of
records for the recipes of the domain.  templates/files/pdns.zone.tt lists the
records.

The purpose is simple DNS delegation of subdomains to provisioned machines.

The server uses the sqlite backend.

C<extra_records> names one plain text file that holds a zonefile fragment.  The
recipe appends it to the zone.  A relative path is relative to the directory of
the domain in the data source.

The recursor lets you point a resolver at this guest for fast answers.  It also
reduces the DNS rate limiting that RBLs apply.

=cut

use Text::Xslate;
use Net::IP;
use File::Slurper;
use Crypt::PRNG();

use Provisioner::Cookbook();

# The API socket as the host sees it.  pdns binds /api.sock inside its chroot,
# which is this path from outside.
our $API_SOCKET = '/var/spool/powerdns/api.sock';

sub rate_limits {

    # A resolver asks over udp and asks often, and a recursor in front of this
    # server asks for everybody behind it.  The limit is high enough that only a
    # reflection flood reaches it.
    #
    # tcp is limited too, because a zone transfer and a large answer use it.
    # An unlimited protocol is the one that a flood uses.
    return ( 53 => 4096, '53/udp' => 4096 );
}

=head2 %required = $recipe->required_recipes(%opts)

Adds C<nostubresolver> and C<lexicon>.

L<Provisioner::Recipe::lexicon> is the client that writes records into the zone
of this server.

This server is the only thing that answers for the zone of the guest, and the
systemd stub resolver does not ask it.  lexicon looks up the zone through the
system resolver for C<--resolve-zone-name>, and step-ca validates dns-01 through
it.  So on the stub, the guest cannot resolve its own name.

L<Provisioner::Recipe::letsencrypt> requires C<nostubresolver> when this server
answers its challenge.  This recipe requires it too, for a guest that serves a
zone without letsencrypt.

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

            # The provider that holds the public zone that this guest syncs to,
            # in the three fields of the registrar recipe.  The operator sets
            # it.  The credentials of this guest go under lexicon, because here
            # they name this guest as its own upstream.
            registrar => {
                type       => 'object',
                properties => {
                    type => { type => 'string', description => 'The lexicon provider holding the zone, spelled as the registrar recipe spells it.' },
                    user => { type => 'string', description => 'The username that provider authenticates with.' },
                    key  => { type => 'string', description => 'The token or password for it.' },
                },
            },

            # The repo.powerdns.com release train to install from.  A release,
            # not auth-master, which is the development branch.  The API is on a
            # unix socket, and lexicon-pdns-af-unix.patch lets lexicon use it.
            # webserver-address takes a socket path only from PowerDNS 5.0.0.
            # On 4.9, pdns_server does not start and says "Unable to convert
            # presentation address".
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

The credentials for the API on the unix socket of this server.  Anything on
this guest writes a record into the zone of this server through that API.  See
L<Provisioner::DNSRecipe> for the keys that come back.

C<opts> is C<--resolve-zone-name>, because lexicon reduces a name to its
registrable form with tldextract before it asks for a zone.  A reserved TLD is
not a public suffix, so without the flag lexicon asks for the zone "test" and
gets a 404.

=cut

sub lexicon_credentials {
    my ( $self, %opts ) = @_;

    # letsencrypt calls this as a class method, on a path where enrich does not run.
    my $key =
        $opts{api_key}
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

Returns the API key of the pdns server on the guest that holds C<$domain>.

If an operator set C<api_key> for that server, it returns that value.  If not,
it makes one random key per server and returns that key on each call.  The API
configuration, the dehydrated hook and the lexicon shortcut must present the
same key, because a different key gets a 401.

The server belongs to a guest, not to a domain.  For a domain that is layered
onto another guest, L<Provisioner::Cookbook/host_of> finds that guest, and the
method returns the key of its server.

=cut

sub api_key_for {
    my ( $self, $domain ) = @_;

    my $server = Provisioner::Cookbook->host_of($domain) // $domain;

    my $configured = Provisioner::Cookbook->domain_config($server)->{ $self->recipe_name }{api_key};
    return $configured if $configured;

    state %made;
    return $made{ $server // q{} } //= Crypt::PRNG::random_bytes_hex(32);
}

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{api_key} = $self->api_key_for( $opts{domain} )
      unless $opts{api_key};

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

    # The whole spool, because pdns opens everything relative to its chroot.
    # 0775, because the pdns group needs to write in the chroot.
    return ( '/var/spool/powerdns' => { from => "$install_dir/$domain/pdns", owner => 'pdns:pdns', mode => '0775' } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # The sqlite database that holds every zone record of the guest.  After
        # a provision it differs from the zonefile, because lexicon writes the
        # DCV records into it, and people add records by hand.  A rebuild that
        # starts from the zonefile loses them.
        #
        # The whole spool comes down, because pdns opens everything relative to
        # its chroot.  The data target puts it back through restores, before
        # the global fragment applies the schema.
        #
        # One zones.db serves every domain on the guest, so only one salvage
        # can go back.  The salvages of the other domains stay in their domain
        # directories, and the guest test reports it.
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
