package Provisioner::Recipe::nginxproxy;

use strict;
use warnings;

use parent qw{Provisioner::Recipe};

use List::Util qw{any};

=head1 Provisioner::Recipe::nginxproxy

=head2 SYNOPSIS

    somedomain:
        nginxproxy:
            proxy_uri: path/to/socket/in/install_dir
            static_dir: www/static
            nocache_prefix: /secure
            backlog: 32768
            ipv6: false

=head2 DESCRIPTION

Sets up reverse proxy rules for the primary application to be deployed.

The idea here is to support aggressive caching of the outputs of the proxied application.
This is implemented through a try_files directive:

    try_files $url $url.html $url/index.html @default

You can set the name of the 'uncached' route to your application,
which is useful if you have necessarily dynamic pages.
Your application will have to strip that part of the route and then route as normal.

In that case we still serve statics as exact matches, but not .html/.htm versions.
This way all your routes (e.g. /foo) can be dynamic while static assets (e.g. styles/foo.css) will
still be served by nginx.

It is up to your application to cull/regenerate/never generate .html versions of your routes when appropriate.

=head2 USE AS DEPENDENCY

In general it is best to use this as a dependency to other recipes.  See tpsgi & tcms recipes for examples.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{nginx-full};
    }
    die "Unsupported packager";
}

sub validate {
    my ( $self, %opts ) = @_;

    #Per-domain stuff
    die "nginxproxy.vhosts must be HASH" unless $opts{vhosts} && ref $opts{vhosts} eq 'HASH';
    foreach my $key (keys(%{$opts{vhosts}})) {
        next unless $key =~ m/\d+/; 
        my $vopts = $opts{vhosts}{$key};
        my $uri = $vopts->{proxy_uri};
        die "Must set proxy_uri in [nginxproxy] section of recipes.yaml" unless $uri;
        my $sd = $vopts->{static_dir};
        die "Must set static_dir in [nginxproxy] section of recipes.yaml" unless $sd;
    }

    # Global options
    $opts{backlog} //= 32768;
    die "nginxproxy.backlog must be a positive integer"
        unless $opts{backlog} =~ /^\d+$/ && $opts{backlog} > 0;

    $opts{ipv6} //= 1;
    $opts{ipv6} = $opts{ipv6} ? 1 : 0;

    return %opts;
}

sub template_files {
    my ($self) = @_;

    return (
        'nginx.global.conf.tt'  => 'nginx.global.conf',
        'nginx.domain.conf.tt'  => 'nginx.domain.conf',
        'nginx.sysctl.conf.tt'  => 'nginx.sysctl.conf',

        #XXX TODO this needs to be in the MAIN target, NOT here
        'openssl.tt' => 'openssl.conf',
    );
}

1;
