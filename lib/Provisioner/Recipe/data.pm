package Provisioner::Recipe::data;

#ABSTRACT: Schlep a domain's data onto the guest.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::data

=head2 SYNOPSIS

This recipe takes no configuration.  C<_global> in recipes.yaml says where the
files of a domain live on the guest, and where they come from:

    _base:
        _global:
            install_dir: /opt/hosts
            data_source: /opt/data

    somedomain:
        deluged:

and, optionally, in the C<_global> of C<_base>:

    transfer_user: whoever_runs_trog_provisioner
    transfer_ip: 192.0.2.10

Neither is required.  The guest fetches from the machine that runs this tool,
as the account that runs it.  It uses an address of that machine that the guest
can reach.  This tool finds all three, unless the configuration above overrides
them.  See L<Trog::Local>.

C<somedomain> above gets this recipe without asking for it.  C<deluged> has
state to put back, so it depends on this recipe.

=head2 DESCRIPTION

Copies the data of a domain onto the guest, and puts back the state that the
recipes salvaged from the old guest.

It reads C<install_dir> and C<data_source> from C<_global>, and has no fields
of its own.  A configuration that gives C<data> a C<to> or a C<from> is refused.

The recipes say what it puts back, and where.  See C<restores> in
L<Provisioner::Recipe>.

=head2 What the key of the guest reaches

The guest fetches from this machine with its own key, as C<transfer_user>.
C<bin/provision> lets that key in for one forced command, C<rsync --daemon>
with the F<rsyncd.conf> that C<bin/new_config> writes into the domain directory.
See L<Trog::Local/THE KEYS OF GUESTS>.
The daemon runs in a bubblewrap sandbox that holds only what the modules serve,
so a bug in rsync reaches no more than the modules do.  The key gets no shell,
and no forwarding.  It reaches these rsync modules, each named for the domain,
and nothing else of this machine:

=over 4

=item C<payload.DOMAIN>

F<data.tar.gz> in the domain directory, which F<setup.sh> fetches.  Nothing
else in that directory, which also holds the key and the manifest of secrets.

=item C<data.DOMAIN>

The data directory of the domain, which this recipe fetches.

=item C<NAME.DOMAIN>

Each directory that a recipe names in C<fetch_sources>, for example the C<skel>
of L<Provisioner::Recipe::adminconfig>.

=back

A tenant is built on the guest of its host, with the key of the host.  So
F<rsyncd.conf> is in the directory of the host, and it includes the modules of
each domain on that guest.  See C<write_rsyncd_conf> in F<bin/new_config>.

A guest built before the keys of guests came from the directory of guest keys
has a line in the F<authorized_keys> of C<transfer_user> instead.  That line
runs a copy of the sandbox in the domain directory of the guest, and it works
until somebody removes it.  The next build of the guest does not remove it.

=cut

sub args {
    return (
        type       => "object",
        properties => {

            # Where the salvaged state of each recipe goes back, keyed on the
            # destination.  The restores() of each recipe fills it in, so
            # nobody writes it by hand.  See Provisioner::Recipe::restores.
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
