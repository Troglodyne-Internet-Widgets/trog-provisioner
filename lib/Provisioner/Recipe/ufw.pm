package Provisioner::Recipe::ufw;

#ABSTRACT: Set up firewall rules for the enabled recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

use File::Path qw{rmtree};

=head1 Provisioner::Recipe::ufw

=head2 SYNOPSIS

    somedomain:
        ufw:
            port_forwards:
                - from: 25
                  to: 2500

=head2 DESCRIPTION

Allows every application profile that ufw knows.  That includes the profiles
that this recipe renders for the enabled recipes, and the profiles of other
installed packages.

Limits the rate of new connections to ssh and to each port that a recipe
listens on.  The networks in C<admin_networks> are exempt from these limits.

Forwards the ports in C<port_forwards>, if you give any.

=cut

=head2 %opts = $recipe->enrich(%opts)

Adds to C<admin_networks> every address of ours that reaches the guest, and
returns C<%opts>.  It takes the addresses from C<transfer_ips>.  If that list
is empty, it takes C<transfer_ip>.  Each address is added once, before the
networks that the operator named.

The provisioner fetches the payload over ssh many times, and then administers
the guest over ssh.  These connections do not always come from the same
address of ours.  If only one address is exempt, the rate limits count the
other.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @nets = @{ $opts{admin_networks} // [] };
    my @ours = @{ $opts{transfer_ips}   // [] };
    push( @ours, $opts{transfer_ip} ) if !@ours && $opts{transfer_ip};

    my %named = map { $_ => 1 } @nets;
    unshift( @nets, grep { $_ && !$named{$_}++ } @ours );
    $opts{admin_networks} = \@nets;

    return %opts;
}

=head2 $value = $recipe->resolve_conflict($path, $mine, $theirs)

If two recipes name different limits for one port in C<rate_limits>, returns
the higher limit.  Any other disagreement goes to
L<Provisioner::Recipe/resolve_conflict>, which dies.

A limit says where the traffic to a port stops being plausible.  The recipe
that expects the most legitimate traffic knows that best.  If the lower limit
wins, a quiet recipe throttles the users of a busy one.

=cut

sub resolve_conflict {
    my ( $self, $path, $mine, $theirs ) = @_;

    return $mine > $theirs ? $mine : $theirs
      if @$path == 2 && $path->[0] eq 'rate_limits';

    return $self->SUPER::resolve_conflict( $path, $mine, $theirs );
}

sub args {
    return (
        type       => 'object',
        properties => {

            # The number of new connections a second that one source can open
            # to a port before the firewall drops more.  These are the only
            # limits.  setup-ufw-ratelimits writes them, and says why ufw's own
            # `limit` is not used.
            #
            # Only ssh is here, because every guest has ssh.  The other ports
            # come from the recipes that listen on them, through
            # Provisioner::Recipe/rate_limits.  If an operator sets a higher
            # limit for a port here, the higher limit applies.
            #
            # The default is on the port, not on the map.  A default on the map
            # applies only when rate_limits is absent.  required_recipes gives
            # rate_limits over whole, so any recipe that listens supplies the
            # map.  A default on the port applies when that key is missing.
            rate_limits => {
                type       => 'object',
                default    => {},
                properties => {
                    22 => { type => 'integer', default => 64 },
                },
            },

            # Networks that are exempt from rate_limits.  enrich adds every
            # address of ours that reaches the guest.
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

# Profiles only for services with fixed ports.  A recipe gives ufw its
# rate_limits and nothing else, so a profile here cannot know a configurable
# port.  A recipe with a configurable port renders its own profile.
my %template2rule = (
    'ufw.pdns.tt'            => 'ufw/pdns',
    'ufw.mail.tt'            => 'ufw/mail',
    'ufw.plexmediaserver.tt' => 'ufw/plexmediaserver',
    'ufw.garage.tt'          => 'ufw/garage',
);

=head2 %files = $recipe->template_files(@recipes)

Removes the C<ufw> directory in C<output_dir> and makes a new, empty one.
Returns the application profiles to render, as a map from template to output
path.  The C<ufw.http.tt> profile is always in the map.  Each recipe in
C<@recipes> that has a profile for fixed ports adds its own.

=cut

sub template_files {
    my ( $self, @recipes ) = @_;

    my $dir = "$self->{output_dir}/ufw";

    rmtree $dir;
    mkdir $dir;

    my %ret = ( 'ufw.http.tt' => 'ufw/http' );

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
