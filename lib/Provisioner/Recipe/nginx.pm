package Provisioner::Recipe::nginx;

#ABSTRACT: Install nginx and its global configuration.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::nginx

=head2 SYNOPSIS

    somedomain:
        nginx:
            backlog: 32768

=head2 DESCRIPTION

Install nginx, set the kernel backlog and worker_connections to C<backlog>, and
install the global configuration of nginx.

With C<syslog>, the default, nginx also sends its access log and its error log
to the syslog of the guest, tagged C<nginx_access> and C<nginx_error>.  So
L<Provisioner::Recipe::logshipper> forwards them.  The files stay, because the
jails of fail2ban read them.  A server block that names its own C<access_log>
replaces the one sent to syslog, so the mirrors of C<aptmirror> and
C<fetchcache> do not send their traffic there.

=head2 USE AS DEPENDENCY

Use this recipe as a dependency of other nginx recipes, not on its own.

=head2 The names that each vhost answers for

nginx gives a name that two server blocks claim to the first one it loads, and
only warns about the other.  So the names of every vhost of a domain are decided
here, in one place, and each vhost reads its own.

A recipe that installs a vhost declares it in C<sites>, from its
C<required_recipes>, under a name of its own choosing:

    nginx => sub {
        my (%opts) = @_;
        return ( sites => { webmail => { names => ["webmail.$opts{domain}"] } } );
    },

A site with C<domain> set serves the domain, and every alias of it that no other
site names.  A site without it serves C<names> alone.  The fragment of this
recipe writes one file for each site, F</etc/nginx/names/$domain/$site.conf>,
which holds its C<server_name>, and the vhost includes that file.

A name that two sites claim, or two sites that each serve the domain, stop the
build, because nginx would serve only one of them.

=cut

sub rate_limits {

    # One page load opens dozens of connections to one origin, and a shared NAT
    # multiplies that by each user behind it.  A thousand a second is not a visitor.
    return ( 80 => 1024, 443 => 1024 );
}

=head2 %jails = $recipe->jails()

The jails that fail2ban ships for nginx: failed basic authentication, and
requests for the paths that bots probe.  Both read the error log of nginx, so
both read the file and not the journal.

=cut

sub jails {
    return (
        'nginx-http-auth' => { backend => 'auto' },
        'nginx-botsearch' => { backend => 'auto' },
    );
}

=head2 @names = $recipe->subdomains()

C<www>, which the vhost of the domain answers for: that site serves the domain
and every alias that no other site names, and www is one of them.

=cut

sub subdomains {
    return qw{www};
}

sub args {
    return (
        properties => {
            backlog => { type => 'integer', default => 32768, minimum => 0 },

            # A domain name is at most 253 characters.  256 is the next multiple
            # of the cache line size, which nginx aligns this value to.
            server_names_hash_bucket_size => { type => 'integer', default => 256, minimum => 32 },

            syslog => {
                type        => 'boolean',
                default     => 1,
                description => 'Also send the access log and the error log to the syslog of the guest, which logshipper forwards.  The files stay either way, because fail2ban reads them.',
            },

            sites => {
                type                 => 'object',
                default              => {},
                description          => 'The vhosts of the domain, keyed on a name for each, which the recipes that install them hand over.  See "The names that each vhost answers for".',
                additionalProperties => {
                    type                 => 'object',
                    additionalProperties => 0,
                    properties           => {
                        names  => { type => 'array',   items   => { type => 'string' }, default => [], description => 'The names that only this vhost answers for.' },
                        domain => { type => 'boolean', default => 0, description => 'This vhost serves the domain, and each alias of it that no other site names.' },
                    },
                },
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Adds C<server_names>: for each site, the names that its vhost answers for.  Dies
when two sites name one name, or when two sites serve the domain.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $sites = $opts{sites};
    my %owner;
    foreach my $site ( sort keys %$sites ) {
        foreach my $name ( @{ $sites->{$site}{names} } ) {
            die "nginx: $name is a name of both the $owner{$name} site and the $site site of $opts{domain}, and nginx would serve only one.\n"
              if $owner{$name};
            $owner{$name} = $site;
        }
    }

    my @serve_domain = grep { $sites->{$_}{domain} } sort keys %$sites;
    die "nginx: the sites @serve_domain all serve $opts{domain}, and nginx would serve only one.\n" if @serve_domain > 1;

    my %server_names = map { $_ => [ @{ $sites->{$_}{names} } ] } keys %$sites;
    if (@serve_domain) {
        my @rest = grep { !$owner{$_} } ( $opts{domain}, @{ $opts{full_aliases} // [] } );
        unshift( @{ $server_names{ $serve_domain[0] } }, @rest );
    }

    foreach my $site ( sort keys %server_names ) {
        die "nginx: the $site site of $opts{domain} answers for no name.\n" unless @{ $server_names{$site} };
    }
    $opts{server_names} = \%server_names;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt' => 'nginx.global.conf',
        'nginx.sysctl.conf.tt' => 'nginx.sysctl.conf',
    );
}

sub tests {
    return qw{nginx.tt};
}

1;
