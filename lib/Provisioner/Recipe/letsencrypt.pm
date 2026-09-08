package Provisioner::Recipe::letsencrypt;

#ABSTRACT: Issue and install TLS certificates via dehydrated and DNS DCV.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

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

The fetch is an sftp session as the admin user with no sudo, and dehydrated
writes every private key it makes C<0600 root>. So the guest has to leave them
readable by that account or the fetch returns an empty directory and says
nothing anybody reads. That is done in two places, and it has to be both:
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

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{certbot lexicon dehydrated};
    }
    die "Unsupported packager";
}

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

sub args {
    return (
        type       => 'object',
        properties => {
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

    # If the user instructs that we ought to use the local DNS server
    # instead of the global registrar info, let's do that.
    # Also make sure that we have the "right stuff" setup otherwise.
    if ( $params{prefer_local_dns} ) {
        die "Must have at least one dns provider recipe used" if !any {
            my $mod = $_;
            grep { $mod eq $_ } qw{pdns}
        } @{ $params{modules} };
        $params{registrar} = {
            type => 'powerdns',
            user => '',
            key  => $params{local_dns_access_token},
        };

        #XXX pretty dopey that the var is POWERDNS_PDNS_SERVER, but load bearing at this point
        $params{extra_lexicon_vars} = [
            { key => 'PDNS_SERVER', value => "/var/spool/powerdns/api.sock" },
            { key => 'DELEGATED',   value => $params{domain}, global => 1 },
        ];
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

    # The ACME account is the identity the CA knows this guest by, and the certs
    # are what a rebuild would otherwise ask for again -- into the rate limit.
    return (
        '/etc/dehydrated/accounts'          => { from => "$install_dir/$domain/.letsencrypt/accounts",          owner => "root:$admin" },
        "/var/lib/dehydrated/certs/$domain" => { from => "$install_dir/$domain/.letsencrypt/var-certs/$domain", owner => "root:$admin" },
    );
}

sub remote_files {
    return (
        '/var/lib/dehydrated/certs/' => '.letsencrypt/var-certs',
        '/etc/dehydrated/accounts/'  => '.letsencrypt/accounts',
    );
}

sub tests {
    return qw{letsencrypt.tt};
}

1;
