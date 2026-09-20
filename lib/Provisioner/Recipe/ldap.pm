package Provisioner::Recipe::ldap;

#ABSTRACT: Install and configure OpenLDAP as a domain identity server.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ldap

=head2 SYNOPSIS

    somedomain:
        ldap:
            admin_password: s3cr3t

Or with a base DN and an LDAPS port of your choice:

    somedomain:
        ldap:
            admin_password: s3cr3t
            base_dn: dc=example,dc=test
            port: 636

=head2 DESCRIPTION

Installs and configures OpenLDAP (slapd) as the identity server of a domain.

The seed adds each user in C<users> as a POSIX account.  Each account has the
C<inetOrgPerson>, C<posixAccount> and C<shadowAccount> object classes.

LDAPS uses C</etc/ssl/certs/E<lt>domainE<gt>.pem> and its key.  The ssl target
makes a self-signed pair there on every guest.  The C<letsencrypt> fetcher
replaces it with a real certificate when it has one.

slapd listens for LDAPS on C<port>, which is 636 by default.  Remote clients,
for example SSSD, use this port.  The firewall profile opens the same value, so
the two agree.  slapd also listens for plain LDAP on port 389 and on the
C<ldapi> socket.

=head2 SURVIVING A REBUILD

The seed is the start of a directory, not its current state.  Users change
passwords and add SSH keys, and operators add groups.  All of that is only in
C</var/lib/ldap>.  A guest rebuilt from the recipe alone has its users as they
were on the day of the first provision.

The recipe does not copy C</var/lib/ldap> or C</etc/ldap/slapd.d> off the guest.
MDB is a private on-disk format.  It is tied to the slapd that wrote it and to
the architecture of that machine, and a rebuilt guest can have a different slapd.

So the recipe exports the directory instead.  C<ldap-export.sh> runs each hour.
It writes C<slapcat> output to C</var/backups/ldap>, which the admin user owns.
C<remote_files> names that directory.  On the next guest, C<ldap-reload.sh>
loads the data with C<slapadd> before the seed runs.  The seed then only adds
what is missing.

The export also holds the configuration database, but the reload does not load
it.  C<cn=config> names the schema, the build paths and the TLS settings of the
slapd that wrote it.  This recipe writes the TLS settings again on each
provision.  If you load an old copy over a new guest, slapd can fail to start
and give no reason.  The export keeps the old configuration so that an operator
can read an ACL or an overlay and add it again by hand.

A rebuild can lose at most the changes of the last hour.

=cut

=head2 @ports = $recipe->listens(%opts)

slapd: LDAP on 389, and LDAP over TLS on C<port>.

=cut

sub listens {
    my ( $self, %opts ) = @_;

    # Defaulted here as well as in args, because required_recipes calls this
    # before validation.
    return ( 389, $opts{port} // 636 );
}

=head2 $bool = $recipe->is_multi_tenant()

Returns false.  A guest has one slapd.  Its suffix, its organization and its
TLS certificate all use the name of the domain that configured it.

If a second domain on the same guest names ldap, its target does not run.  It
does not overwrite the first directory, but it gets no directory of its own.

=cut

sub is_multi_tenant { return 0 }

sub args {
    return (
        type       => 'object',
        required   => [qw{admin_password}],
        properties => {
            admin_password => { type => 'string' },
            base_dn        => { type => 'string' },
            port           => { type => 'integer', default => 636 },
            users          => {
                type    => 'array',
                default => [],
                items   => {
                    type       => 'object',
                    properties => {
                        gecos         => { type => 'string' },
                        mail          => { type => 'string', description => 'The mail attribute the seed gives this user.  Left out of the seed when it is not set.' },
                        name          => { type => 'string' },
                        shell         => { type => 'string' },
                        ssh_import_id => { type => 'array', items => { type => 'string' } },
                        sudo          => { type => 'string' },
                    },
                },
            },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # example.test becomes dc=example,dc=test.
    unless ( $opts{base_dn} ) {
        my $domain = $opts{domain} // '';
        my @parts  = split( /[.]/, $domain );
        $opts{base_dn} = join( ',', map { "dc=$_" } @parts );
    }

    # slapd makes its base DN from the domain that debconf gives it.  So that
    # domain comes from base_dn, not from the hostname, or the seed cannot bind.
    ( $opts{ldap_domain} = $opts{base_dn} ) =~ s/\bdc=//g;
    $opts{ldap_domain} =~ tr/,/./;

    # The dc of the base entry must be the first component of base_dn.  An
    # operator who sets base_dn can name a tree that the hostname does not.
    ( $opts{base_dc} ) = $opts{base_dn} =~ m/\Adc=([^,]+)/;

    return %opts;
}

sub template_files {
    my ($self) = @_;
    return (
        'ldap.apparmor.tt'      => 'slapd.apparmor',
        'ldap.slapd.debconf.tt' => 'slapd.debconf',
        'ldap.seed.ldif.tt'     => 'seed.ldif',
        'ldap.tls.ldif.tt'      => 'tls.ldif',
        'ldap.export.sh.tt'     => 'ldap-export.sh',
        'ldap.export.cron.tt'   => 'ldap-export.cron',
        'ldap.reload.sh.tt'     => 'ldap-reload.sh',

        # A ufw application profile for the port.  setup-ufw-rules allows each
        # profile that `ufw app list` shows.
        'ldap.ufw.conf.tt' => 'ldap_ufw.conf',
    );
}

=head2 @commands = $recipe->remote_prepare($install_dir, $domain)

Returns C<ldap-export.sh>, which the guest runs before the fetch.  The cron runs
it each hour, so without this call a rebuild can lose up to an hour of changes.

=cut

sub remote_prepare {
    return ('/usr/local/sbin/ldap-export.sh');
}

sub restores {
    my ( $self,        %opts )   = @_;
    my ( $install_dir, $domain ) = @opts{qw{install_dir domain}};

    # admin_user falls back to root, because required_recipes runs before
    # validation, and bin/new_guest scaffolds with whatever _global has.
    # Nothing keeps the answer: a scaffold asks only whether the dependency is
    # there, and the run that configures the guest asks again with an
    # admin_user.
    my $admin = $opts{admin_user} // 'root';

    # Into the export directory, not into slapd.  The export writes there and
    # the fetch reads there.  ldap-reload.sh loads it into slapd later.
    return ( '/var/backups/ldap' => { from => "$install_dir/$domain/ldap", owner => "$admin:$admin" } );
}

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return (
        '/var/backups/ldap/' => 'ldap',
    );
}

sub tests {
    return qw{ldap.tt};
}

1;
