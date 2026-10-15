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
here, in one place.

A recipe that installs a vhost lists the names of its vhost in C<sites>, from
its C<required_recipes>:

    nginx => sub {
        my (%opts) = @_;
        return ( sites => ["webmail.$opts{domain}"] );
    },

A vhost that serves the primary domain being provisioned lists that domain.
That vhost also answers for every alias that the operator configured for the
domain and no other vhost lists, so it does not know its names in advance.  The fragment of this recipe
writes them to F</etc/nginx/names/$domain.conf> as its C<server_name>, and
that vhost includes the file.  A vhost writes the names that it lists itself
in a C<server_name> of its own, such as C<www> beside that file.

A name that two recipes list stops the build, because nginx would serve only
one of them.  So two recipes whose vhosts serve the domain cannot be on one
guest.

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
                type        => 'array',
                items       => { type => 'string' },
                default     => [],
                description => 'The names that the vhosts of the domain answer for, which the recipes that install them hand over.  The vhost that serves the primary domain being provisioned lists it, and also answers for each alias that no other vhost lists.  See "The names that each vhost answers for".',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

When a vhost serves the domain, adds C<domain_names>: the domain, and each
alias of it that no vhost lists.  Dies when two recipes list one name.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my %listed;
    $listed{$_}++ foreach @{ $opts{sites} };
    foreach my $name ( sort keys %listed ) {
        die "nginx: invalid configuration: multiple recipes configured to serve $name\n" if $listed{$name} > 1;
    }

    $opts{domain_names} = [ $opts{domain}, grep { !$listed{$_} } $self->domain_aliases(%opts) ] if $listed{ $opts{domain} };

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
