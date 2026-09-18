package Provisioner::Recipe::perl;

#ABSTRACT: Build and install the latest perl into /opt/perl5, with what other recipes install into it from CPAN.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::Recipe};

=head1 Provisioner::Recipe::perl

=head2 SYNOPSIS

    somedomain:
        perl:

=head2 DESCRIPTION

This recipe downloads the latest perl, compiles it and installs it into
/opt/perl5/$version.

It writes F</etc/profile.d/perl.sh>, so a person who logs in gets that perl
first.  Nothing in a build reads shell init.  make runs its recipe lines under a
non-interactive sh from an atd job, and systemd and cron read no shell init
either.  So everything that installs into this perl finds it under
F</opt/perl5>.

F<scripts/build_latest_perl.sh> always gives the perl three modules, whatever
else a recipe asks for.  The C<cpan> of the new perl installs B<cpanm>, because
nothing else can install it yet.  Then cpanm installs B<Module::Build> and
B<Dist::Zilla>, because a distribution that needs either cannot install it for
itself.  Everything else comes from C<cpan_deps>.

Those last two, and each step of C<cpan_deps>, go through
F<scripts/cpan_install>.  That script is the one thing on a guest that gets
modules from CPAN.  CPAN.pm installs cpanm and nothing else, and
F<scripts/build_latest_perl.sh> says why.  cpan_install installs the release
that the index of the mirror names, not the one that cpanmetadb names.  A
version pin that needs an older release is the exception.

TODO: let the configuration choose the version of perl.

=head2 What other recipes install into it

A recipe that installs from CPAN depends on this one and gives it the steps as
C<cpan_deps>.  This is the example from tpsgi.  It installs Starman, which
starts its service, and what its checkout says it needs:

    perl => sub {
        my (%opts) = @_;
        return (
            cpan_deps => [
                { install     => ['Starman'] },
                { installdeps => Path::Tiny::path( @opts{qw{install_dir domain}} )->stringify },
            ],
        );
    },

C<bin/new_config> merges the lists from every dependent, each list after the
one before, so this recipe is configured once with all of them.  Anything
written under C<perl> for the domain itself comes after those.  Each step is a
hash that names one of four verbs, which are the verbs of
F<scripts/cpan_install>:

    { install     => [ 'Dist::Zilla', 'Moo~>= 2.004', 'Sys::Virt@10.0.0' ] }
    { installdeps => '/opt/domains/example.test/tCMS' }
    { dzil        => '/opt/domains/example.test/checkout' }
    { pin         => { module => 'Sys::Virt', pkgconfig => 'libvirt' } }

F<scripts/cpan_install> says what each verb installs.

The schema holds each step to one verb with nothing beside it.  No word can
contain a quote, a dollar, a backtick, a backslash or a newline.  Any of those
stops the word reaching cpan_install as one word, through a makefile line and
the shell that runs it.

=head2 When they are installed, and why then

The target of this recipe installs them straight after it builds the perl, in
the order they were handed over.  It does not defer them.

That target runs after the fragment of every recipe that depends on this one,
because C<bin/new_config> puts a required recipe after the last recipe that
requires it.  So a checkout that the fragment of a dependent makes is there to
install from.  The target also finishes before the deferred work starts, so a
service that a dependent starts in the postrun has its modules by then.
If this recipe defers them, they go into the queue behind what those
dependents already queued, which includes the service start.

If a step fails, the makefile stops, the same as when the perl fails to build.

=cut

# A word that reaches cpan_install whole, single-quoted in a makefile line.
my %WORD = ( type => 'string', pattern => q{\A[^'"$`\\\\\n]+\z} );

my %STEP = (
    type                 => 'object',
    additionalProperties => 0,
    properties           => {
        install     => { type => 'array', minItems => 1, items => {%WORD} },
        installdeps => {%WORD},
        dzil        => {%WORD},
        pin         => {
            type                 => 'object',
            additionalProperties => 0,
            required             => [qw{module pkgconfig}],
            properties           => { module => {%WORD}, pkgconfig => {%WORD} },
        },
    },
    oneOf => [ map { { required => [$_] } } qw{install installdeps dzil pin} ],
);

sub args {
    return (
        type => 'object',

        properties => {

            # Empty by default.  The recipes that depend on this one fill it,
            # and the build script installs cpanm, Module::Build and Dist::Zilla.
            cpan_deps => {
                type        => 'array',
                default     => [],
                items       => \%STEP,
                description => 'What the recipes depending on this one install into it, handed over by them: see perldoc Provisioner::Recipe::perl.  Each step names one of install, installdeps, dzil or pin.  Installed in this target, in the order handed over.',
            },
            cpan_notest => {
                type        => 'boolean',
                default     => 1,
                description =>
                  'Skip the test suites of what cpan_deps installs into this perl.  On by default: a guest has ninety minutes for its makefile and deferred work together, and the suites of everything a recipe like trogrunner installs do not fit.  Turn it off when what you are testing is what gets installed.  Set in _global to reach every guest, which is what the provisioning-recipes skill scratch_config --cpan-tests does.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with C<cpan_steps> added.  For each step of C<cpan_deps>, that
holds the words that go to F<scripts/cpan_install> after the optional
C<--notest>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    $opts{cpan_steps} = [ map { [ _words($_) ] } @{ $opts{cpan_deps} } ];
    return %opts;
}

sub _words {
    my ($step) = @_;

    return ( 'install', @{ $step->{install} } )                   if $step->{install};
    return ( 'pin',     @{ $step->{pin} }{qw{pkgconfig module}} ) if $step->{pin};

    my ($verb) = grep { exists $step->{$_} } qw{installdeps dzil};
    return ( $verb, $step->{$verb} );
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

=head2 @hosts = $recipe->fetch_hosts()

CPAN.  This recipe reaches it three ways.  perlbrew gets the source of the perl
that it builds.  The C<cpan> of that perl gets cpanm.  cpanm gets Module::Build,
Dist::Zilla and each C<cpan_deps> step.  MetaCPAN says which release a version
pin names, and the mirrors serve it.

=cut

sub fetch_hosts {
    return qw{www.cpan.org cpan.metacpan.org fastapi.metacpan.org};
}

=head2 @classes = $recipe->cache_classes()

CPAN.  The index and the MetaCPAN API say which release is current.  A
distribution under F<authors/id> is named by its version and never changes.
CHECKSUMS is excluded, because it is written again whenever anything beside it
changes.

=cut

sub cache_classes {
    return (
        { class => 'index',     pattern => 'fastapi\.metacpan\.org/' },
        { class => 'index',     pattern => '[^/]+/modules/' },
        { class => 'immutable', pattern => '[^/]+/authors/id/(?!.*/CHECKSUMS$)' },
    );
}

1;
