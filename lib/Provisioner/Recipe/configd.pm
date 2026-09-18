package Provisioner::Recipe::configd;

#ABSTRACT: Give the services with no conf.d one, so two domains can both configure them.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{uniq};

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::configd

=head2 SYNOPSIS

    somedomain:
        configd:
            languages:
                - postfix
                - redis

Usually you do not write that.  The recipes for the services that configd
covers ask for it, with the languages that they need:

    somedomain:
        mail:
        redis:

=head2 DESCRIPTION

Installs L<Configd|https://metacpan.org/pod/Configd> and gives it the
configuration files that C<languages> names.

Postfix, opendkim, opendmarc and redis each keep their configuration in one
file, with no C<conf.d> directory.  If you provision two domains onto one guest,
the second run replaces what the first run wrote.

Postfix is the dangerous case, because it gives no error.
C<postconf -e mydestination=second.example.test> does not add the second
domain.  It removes the first domain, and postfix stops local delivery of the
mail for that domain.

C<configd adopt> gives such a file a fragment directory next to it, for example
C</etc/postfix/main.cf.d>.  It moves the current file into that directory as
C<00-original>.  It installs a systemd drop-in that makes the file again from
the fragments each time the service starts or reloads.

After that, a recipe configures the service with a file in that directory,
named for its domain.  Configd merges the parameters that are lists, and does
not overwrite them.

=head3 What this changes for a recipe

L<Provisioner::Recipe> tells you to put the configuration of a service with no
C<conf.d> in the global half of a recipe.  This recipe removes that
restriction.  A recipe that a language covers writes a fragment for each
domain, and the domains do not have to agree.

=head3 Which perl

Configd uses the system perl, C</usr/bin/perl>, not the C</opt/perl5> build
that the C<perl> recipe makes.  C<configd> runs from an C<ExecStartPre>, so a
service cannot start if configd fails.  It must work on a guest that does not
have the C</opt/perl5> build.  It must continue to work if that build is
rebuilt or removed.

Everything that Configd needs is core, so the perl of the distribution is
sufficient.  C<scripts/install_configd> makes sure of this in three places,
because each one can install into the wrong perl without an error.

=head3 What it does not do

It does not restart a service.  Adoption makes the files again, and the recipe
that owns the service knows when a restart is safe.  C<mail> and C<redis> each
queue their own restarts.

After the makefile, this recipe queues a second C<configd adopt>.  That run
makes the files again from the fragments that all recipes wrote.  It reloads
systemd, so that the drop-in is live, and it does a C<try-restart> of the
services that are running.

=head3 deps

C<cpanminus> and C<make>, which cpanm needs to get a distribution from CPAN.
Configd itself needs only core modules.

=head3 args

=over 4

=item languages

The configuration file formats to adopt, by name: C<postfix>, C<opendkim>,
C<opendmarc>, C<redis>, or any other name that has a C<Configd::Language::>
module in the installed Configd.  A name must be word characters only, because
each name becomes part of a module name and a shell argument.

The recipe removes duplicate names and sorts the list.  Several recipes that ask for the same
language are the normal case, not a mistake.

=item version

The minimum version of Configd to accept.  If the guest already has that
version, the recipe does not go to CPAN, so a new provision of the guest is
fast.

=item source

Where to get Configd, if not from CPAN.  This is anything that C<cpanm> accepts
in place of a module name, for example a tarball on the guest or a URL.  Use it
for a build that is not released, or for a guest that cannot connect to CPAN.
The install is still held to C<version>, because cpanm does not know the
version of a source until it unpacks it.

=back

=cut

sub args {
    return (
        type       => 'object',
        properties => {
            languages => {
                type    => 'array',
                default => [],

                # A language name comes from the configuration, and becomes part
                # of a module name and a shell argument.
                items => { type => 'string', pattern => '^\w+$' },
            },

            # 0.002 is the first version that accumulates
            # smtpd_sender_login_maps.  With 0.001, a guest with two mail
            # domains names the table of only one domain there.  Then
            # reject_authenticated_sender_login_mismatch refuses mail from the
            # users of every other domain.  install_configd fails the build if
            # it gets an older version.
            version => { type => 'string', default => '0.002' },

            source => { type => 'string' },
        },
    );
}

sub enrich {
    my ( $self, %opts ) = @_;

    # When several recipes ask for one language, the merge concatenates their
    # lists, so the same name can arrive more than once.
    $opts{languages} = [ sort( uniq( @{ $opts{languages} // [] } ) ) ];

    return %opts;
}

sub tests {
    return qw{configd.tt};
}

1;
