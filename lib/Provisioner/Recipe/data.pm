package Provisioner::Recipe::data;

#ABSTRACT: Schlep data from the hypervisor onto the guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::data

=head2 SYNOPSIS

In recipes.yaml:

    somedomain:
        data:
           - from: /opt/domaindata/my.domain
             to: /opt/domains/my.domain
           - from: /foo/bar
             to: /baz

In ipmap.cfg:

    transfer_user=whoever_runs_trog_provisioner

=head2 DESCRIPTION

Schlep data from the hypervisor onto the guest, and put back whatever the
recipes salvaged off the last one.

C<from> and C<to> default to C<data_source> and C<install_dir> out of
C<_global>, which is where they belong: every recipe interpolates
C<install_dir>, and it used to be read out of this recipe's C<to> field -- so
each of them depended on this one for a path rather than for anything it does.
Saying them here still wins, for a configuration written before the move.

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{openssh-server openssh-client rsync};
    }
    die "Unsupported packager";
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Where this domain lives is _global's to say now, and this recipe moves
    # things into it rather than deciding what it is.  Said explicitly under
    # data it still wins, for a configuration written before the move.
    # Not `required` in args, because validation runs before this does and a
    # field somebody is about to be given a default for is not a field they
    # failed to provide.  Which leaves saying so here.
    $opts{to}   //= $opts{install_dir};
    $opts{from} //= $opts{data_source};

    die "data has nowhere to put anything: set install_dir in _global, or to under data.\n"
      unless defined $opts{to} && length $opts{to};

    die "data has nothing to bring: set data_source in _global, or from under data.\n"
      unless defined $opts{from} && length $opts{from};

    return %opts;
}

sub args {
    return (
        type       => "object",
        properties => {

            # The account that owns this domain's files.  Every template using
            # it did so bare, and nothing declared it, so it rendered empty --
            # `chown -R :group`, which quietly changes only the group.
            user => { type => 'string' },
            from => { type => "string" },
            to   => { type => "string" },

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
