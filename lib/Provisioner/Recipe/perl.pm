package Provisioner::Recipe::perl;

#ABSTRACT: Build and install the latest perl into /opt/perl5.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perl

=head2 SYNOPSIS

    somedomain:
        perl:

=head2 DESCRIPTION

Downloads the latest perl, compiles it and slams it into /opt/perl5/$version

Sets up a .bashrc in the install_dir which includes that perl's bindir in $PATH.

Its cpanm comes from the App::cpanminus tarball, and C<cpan_modules> are installed
into it straight after, both through F<scripts/cpan_install> and so through the
fleet's fetch cache when there is one.  What other recipes install into it is
their C<cpan_deps>.

TODO: allow specification of version.

=cut

sub args {
    return (
        type => 'object',

        # user is not required, because enrich fills it in from admin_user and
        # enrich runs after validation -- a required field cannot be satisfied
        # by one.  It is always set by the time a template sees it.
        properties => {
            user => { type => 'string' },

            # Installed while the perl is built rather than queued like a
            # recipe's cpan_deps: build_latest_perl.sh links these tools into
            # the user's bin once they are there, and starman has to be there
            # before anything deferred starts a service with it.
            #
            # Module names, spelled as CPAN's index spells them: through the
            # fetch cache cpanm reads that index and matches exactly, where
            # MetaCPAN's search forgave `starman`.
            #
            # Not `modules`: bin/new_config hands every render a `modules` of its
            # own, the recipes on the guest, after the recipe's configuration.
            cpan_modules => {
                type        => 'array',
                items       => { type => 'string', pattern => '\A[\w:]+\z' },
                default     => [qw{Test2 Devel::NYTProf Starman Perl::Critic Perl::Tidy}],
                description => 'Modules installed into the new perl as it is built, through the fetch cache when there is one.  Every run, not only the first, so one added here reaches a guest whose perl is already built.',
            },
        },
    );
}

sub template_files {
    return (
        'perl.critic.rc.tt' => 'perl.critic.rc',
        'perl.tidy.rc.tt'   => 'perl.tidy.rc',
    );
}

sub tests {
    return qw{perl.tt};
}

1;
