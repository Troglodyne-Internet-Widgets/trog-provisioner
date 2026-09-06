package Provisioner::Recipe::configd;

#ABSTRACT: Give the services with no conf.d one, so two domains can both configure them.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use List::Util qw{uniq};

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::configd

=head2 SYNOPSIS

    somedomain:
        configd:
            languages:
                - postfix
                - redis

Usually you do not write that. The recipes for the services it covers ask for
it themselves, with the languages they need:

    somedomain:
        mail:
        redis:

=head2 DESCRIPTION

Installs L<Configd|https://metacpan.org/pod/Configd> and hands it the config
files named by C<languages>.

Postfix, opendkim, opendmarc and redis each keep their configuration in one
file with no C<conf.d> to add to, so two domains provisioned onto one guest
cannot both configure them: the second run replaces what the first wrote.
Postfix is the one that bites, because it is quiet -- C<postconf -e
mydestination=second.example.com> does not add the second domain, it forgets
the first, and mail for it simply stops being delivered locally.

C<configd adopt> gives such a file a fragment directory beside it --
C</etc/postfix/main.cf.d> -- moves what is there now into it as C<00-original>,
and installs a systemd drop-in that regenerates the file from the fragments
every time the service starts or reloads. After that a recipe configures the
service by dropping a file named for its domain into that directory, and the
parameters that are lists are merged as lists rather than overwritten.

=head3 What this changes for a recipe

The advice in L<Provisioner::Recipe> that configuration for a service with no
C<conf.d> belongs in the global half of a recipe is what this exists to lift.
A recipe covered by a language writes a per-domain fragment instead, and the
domains stop having to agree.

=head3 Which perl

The system one, C</usr/bin/perl>, and not the C</opt/perl5> build the C<perl>
recipe makes. C<configd> runs from an C<ExecStartPre>, so it stands between a
service and starting: it has to work on a guest where that perl was never
built, and keep working if it is rebuilt or removed. Everything Configd needs
is core, so the distribution's perl is enough -- see C<scripts/install_configd>,
which is careful about it in three separate places because each of them was
capable of quietly installing into the wrong one.

=head3 What it does not do

It does not restart anything. Adoption regenerates the files, and the recipe
that owns the service is the one that knows when it is safe to restart it --
C<mail> and C<redis> both queue their own. What this queues for after the
makefile is a second C<configd adopt>, which regenerates from whatever every
recipe ended up writing, reloads systemd so the drop-in is live, and
C<try-restart>s the services that are running.

=head3 deps

C<cpanminus> and C<make>, which is what fetching a distribution from CPAN takes.
Configd itself needs nothing that is not core.

=head3 args

=over 4

=item languages

The config file formats to adopt, by name: C<postfix>, C<opendkim>,
C<opendmarc>, C<redis>, or anything else the installed Configd has a
C<Configd::Language::> for. Names are word characters only, because each one
becomes both a module name and a shell argument.

Deduplicated and sorted, since several recipes asking for the same language is
the normal case rather than a mistake.

=item version

The minimum Configd to accept. A guest that already has it does not go to CPAN
at all, so this is also what makes re-provisioning cheap.

=item source

Where to get it, if not CPAN: anything C<cpanm> takes in place of a module name,
so a tarball on the guest or a URL. For a build that has not been released yet,
and for a guest with no route to CPAN. Whatever it installs is still held to
C<version>, because a source is not asked what it is until it is unpacked.

=back

=cut

sub deps {
    my ($self) = @_;
    if ( $self->{target_packager} eq 'deb' ) {
        return qw{cpanminus make};
    }
    die "Unsupported packager";
}

sub args {
    return (
        type       => 'object',
        properties => {
            languages => {
                type    => 'array',
                default => [],

                # A language name becomes part of a module name and an argument
                # to a shell command, and is the one thing here that arrives
                # from configuration rather than from a recipe.
                items => { type => 'string', pattern => '^\w+$' },
            },

            # 0.002 accumulates smtpd_sender_login_maps.  Not a nicety: on
            # 0.001 a guest with two mail domains gets one domain's table named
            # there, and reject_authenticated_sender_login_mismatch then refuses
            # every other domain's users when they send.  install_configd fails
            # the build rather than quietly installing an older one.
            version => { type => 'string', default => '0.002' },

            # Anything cpanm takes in place of a module name: a tarball on the
            # guest, or a URL.  For a build that is not on CPAN yet, and for a
            # guest that cannot reach CPAN.  What it installs is still held to
            # C<version>.
            source => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # Several recipes wanting the same language is the normal case: mail asks
    # for postfix and so would anything else that sends mail.  They arrive
    # concatenated, because that is what merging two lists does.
    $opts{languages} = [ sort( uniq( @{ $opts{languages} // [] } ) ) ];

    return %opts;
}

sub tests {
    return qw{configd.tt};
}

1;
