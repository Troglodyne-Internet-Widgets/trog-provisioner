package Provisioner::Recipe::pdns;

#ABSTRACT: Set up the PowerDNS resolver and install DNS records.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

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

Appends arbitrary records (in plain text files, basically a zonefile fragment) specified as extra_records.  Relative to the datadir if not absolute path.

Sets up the recursor in the event you want to point your resolver at it for fast resolves and to mitigate DNS rate-limiting by RBLs.

=cut

use Text::Xslate;
use Net::IP;
use File::Slurper;

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{pdns-server pdns-recursor pdns-tools pdns-backend-sqlite3 sqlite3 libconfig-simple-perl libnet-dns-perl libjson-perl python3-requests-unixsocket};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        required   => [qw{api_key}],
        properties => {
            api_key       => { type => 'string' },
            extra_records => { type => 'string' },
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
            repo_branch   => { type => 'string', default => 'auth-51',
                               pattern => '^auth-[0-9]+$' },
            # Zones to forward to another resolver, as zone => address.  There
            # is no default: what used to be here was one hardcoded
            # test.test=192.168.1.1, appended to the recursor configuration on
            # every provision.
            forward_zones => { type => 'object', default => {} },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    my $extras = $opts{extra_records} // '';
    if ($extras) {
        my $is_abs_path = index($extras, '/') == 0;
        $extras = "$opts{data_source}/$opts{domain}/$extras" unless $is_abs_path;
        $opts{extra_records} = File::Slurper::read_text($extras);
    }

    $opts{serial} = time;
    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'pdns.zone.tt'                                 => 'zonefile',
        'pdns.domain.tt'                               => 'pdns-domain.conf',
        'pdns.global.tt'                               => 'pdns-global.conf',
        'pdns.recursor.tt'                             => 'pdns-recursor-domain.conf',
        'pdns.rsyslog.tt'                              => '10-powerdns.conf',
        'pdns.api.tt'                                  => 'pdns-api.conf',
        'pdns.synczones.tt'                            => 'synczones.conf',
        'pdns.lexicon.tt'                              => 'lexicon-pdns.sh',
        'patches/lexicon-pdns-af-unix.patch'           => 'lexicon-pdns-af-unix.patch',
        'patches/lexicon-arbitrary-record-types.patch' => 'lexicon-arbitrary-record-types.patch'
    );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        # SQLite database containing all DNS zone records
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

1;
