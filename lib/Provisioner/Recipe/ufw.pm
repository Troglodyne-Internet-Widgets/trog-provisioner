package Provisioner::Recipe::ufw;

#ABSTRACT: Set up firewall rules for the enabled recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::ufw

=head2 SYNOPSIS

    somedomain:
        ufw:
            port_forwards:
                - from: 25
                  to: 2500

=head2 DESCRIPTION

Sets up application rules for all your enabled recipes (and whatever else is installed on the system).

Optionally set up port forwarding.

=cut

use File::Path qw{rmtree};

sub enrich {
    my ( $self, %opts ) = @_;

    # Every address the provisioner can arrive from is one, whether or not
    # anybody said so: it fetches the payload over ssh repeatedly and then
    # administers the guest over ssh again, and those are not always the same
    # address of ours -- a remote hypervisor is reached over the guest's static
    # address and a local one over its NAT lease.  Naming only the one the
    # payload came from leaves the other counted by the limit.
    my @nets = @{ $opts{admin_networks} // [] };
    my @ours = @{ $opts{transfer_ips}   // [] };
    push( @ours, $opts{transfer_ip} ) if !@ours && $opts{transfer_ip};

    my %named = map { $_ => 1 } @nets;
    unshift( @nets, grep { defined $_ && length $_ && !$named{$_}++ } @ours );
    $opts{admin_networks} = \@nets;

    return %opts;
}

sub resolve_conflict {
    my ( $self, $path, $mine, $theirs ) = @_;

    # Two recipes listening on the same port each name a limit for it, and the
    # higher one is the safe answer: a limit says where traffic to that port
    # stops being plausible, and the recipe expecting the most legitimate
    # traffic is the one that knows.  Taking the lower would let a quiet recipe
    # throttle a busy one's users, so adding a recipe could break a working one.
    return $mine > $theirs ? $mine : $theirs
      if @$path == 2 && $path->[0] eq 'rate_limits';

    # Anything else here is a genuine disagreement, and the base class says so.
    return $self->SUPER::resolve_conflict( $path, $mine, $theirs );
}

sub args {
    return (
        type       => 'object',
        properties => {

            # New connections a second a single source may open to a port
            # before it is dropped.  ufw's own `limit` is six in thirty seconds,
            # which is right for ssh and rate limits real visitors off a web
            # server -- so setup-ufw-rules limits only OpenSSH and these are the
            # real limits.
            #
            # Only ssh is named here, because ssh is the one port every guest
            # has whether or not any recipe asked for it.  The rest arrive from
            # the recipes that actually listen, through their rate_limits: see
            # Provisioner::Recipe::rate_limits.  Setting a port here still wins
            # if it is higher, which is how an operator raises one.
            #
            # The default is on the port rather than on the map holding it.  A
            # default one level up means "when this property is absent", and
            # required_recipes hands rate_limits over whole -- so the first
            # recipe that listened on anything supplied the key, and ssh's limit
            # was never filled in on any guest that had one.  On the property it
            # means "when this key is missing from the map", which is what was
            # always meant by it.
            rate_limits => {
                type       => 'object',
                default    => {},
                properties => {
                    22 => { type => 'integer', default => 64 },
                },
            },

            # Networks allowed in without ufw's rate limit.  Its limit denies a
            # source that opens six connections in thirty seconds, and a
            # provision opens far more than that -- so without an exemption the
            # provisioner throttles itself out of the guest partway through
            # building it, and everything after that fails as "connection
            # refused" on an address that worked a minute earlier.
            admin_networks => {
                type    => 'array',
                items   => { type => 'string' },
                default => [],
            },
            port_forwards => {
                type  => 'array',
                items => {
                    type       => 'object',
                    required   => [qw{from to}],
                    properties => {
                        from => { type => 'integer' },
                        to   => { type => 'integer' },
                    },
                },
            },
        },
    );
}

# Profiles for services whose ports this recipe can actually know, which means
# the ones that are fixed.  A recipe hands ufw its rate_limits and nothing else,
# so a profile here cannot name a port the other recipe made configurable --
# redis and openvpn both did, and both are rendered by their own recipes now.
my %template2rule = (
    'ufw.pdns.tt'            => 'ufw/pdns',
    'ufw.mail.tt'            => 'ufw/mail',
    'ufw.plexmediaserver.tt' => 'ufw/plexmediaserver',
    'ufw.garage.tt'          => 'ufw/garage',
);

sub template_files {
    my ( $self, @recipes ) = @_;

    my $dir = "$self->{output_dir}/ufw";

    rmtree $dir;
    mkdir $dir;

    # Only render the profiles this guest actually needs
    my %ret = (
        'ufw.rsyslog.tt' => 'ufw/rsyslog',
        'ufw.http.tt'    => 'ufw/http',
    );

    return %ret unless @recipes;

    foreach my $r (@recipes) {
        my $key = "ufw.$r.tt";
        $ret{$key} = $template2rule{$key} if exists $template2rule{$key};
    }

    return %ret;
}

sub tests {
    return qw{ufw.tt};
}

1;
