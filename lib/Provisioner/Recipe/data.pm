package Provisioner::Recipe::data;

#ABSTRACT: Schlep a domain's data onto the guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::data

=head2 SYNOPSIS

Nothing configures this.  Where a domain's files live and where what is shipped
to it comes from are C<_global>'s to say, in recipes.yaml:

    _base:
        _global:
            install_dir: /opt/domains
            data_source: /opt/data

    somedomain:
        deluged:

and, optionally, in ipmap.cfg:

    transfer_user=whoever_runs_trog_provisioner
    transfer_ip=192.0.2.10

Neither is required.  The guest fetches from the machine running this tool, as
the account running it, at whichever of that machine's addresses a guest can
reach -- and all three are worked out unless something here overrides them.  See
L<Trog::Local>.

C<somedomain> above gets this recipe without asking for it, because C<deluged>
has state to put back and depends on the thing that puts it there.

=head2 DESCRIPTION

Schlep a domain's data onto the guest, and put back whatever the recipes
salvaged off the last one.

It reads C<install_dir> and C<data_source> and has no fields of its own.  They
used to be this recipe's C<to> and C<from>, which meant every recipe that
interpolates C<install_dir> -- nearly all of them -- depended on this one for a
path rather than for anything it does.  A configuration still saying them here
goes on working: L<Provisioner::Cookbook> reads C<install_dir> out of C<to> and
C<data_source> out of C<from> when C<_global> is quiet.

What it puts back, and where, comes from the recipes: see C<restores> in
L<Provisioner::Recipe>.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openssh-server openssh-client rsync};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => "object",
        properties => {

            # The account that owns this domain's files.  Every template using
            # it did so bare, and nothing declared it, so it rendered empty --
            # `chown -R :group`, which quietly changes only the group.
            user => { type => 'string' },

            # Where each recipe's salvaged state goes back, keyed on the
            # destination.  Nobody writes this by hand: it is what every recipe
            # depending on this one handed over through its restores(), the way
            # ufw is handed rate_limits.  See Provisioner::Recipe::restores.
            restores => {
                type                 => 'object',
                additionalProperties => {
                    type       => 'object',
                    required   => [qw{from}],
                    properties => {
                        from  => { type => 'string' },
                        owner => { type => 'string' },
                        mode  => { type => 'string' },
                    },
                },
            },
        },
    );
}

sub tests {
    return qw{data.tt};
}

1;
