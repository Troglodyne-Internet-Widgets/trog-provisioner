package Provisioner::Recipe::perl;

#ABSTRACT: Build and install the latest perl into /opt/perl5, with what other recipes install into it from CPAN.

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

Writes F</etc/profile.d/perl.sh>, so a person logging in gets that perl first.
Nothing in a build reads shell init -- make runs its recipe lines under a
non-interactive sh out of an atd job, and systemd and cron read none either --
so everything that installs into this perl finds it under F</opt/perl5>
instead.

Three modules come with it whatever else is asked of this recipe, installed by
F<scripts/build_latest_perl.sh>: B<cpanm>, from the new perl's own C<cpan>
because nothing else can install one yet, and then B<Module::Build> and
B<Dist::Zilla> through cpanm, which a distribution needing either cannot install
for itself.  Everything else is C<cpan_deps>.  Both go through
F<scripts/cpan_install>, the one thing on a guest that reaches CPAN -- CPAN.pm
is asked for nothing but the cpanm it bootstraps, having once given up on a
fetch two hundred distributions into Dist::Zilla's tree.

TODO: allow specification of version.

=head2 What other recipes install into it

A recipe that installs from CPAN depends on this one and hands its steps over as
C<cpan_deps>.  tpsgi's, which is what its checkout says it needs, and the
starman its service is started with:

    perl => sub {
        my (%opts) = @_;
        return (
            cpan_deps => [
                { install     => ['Starman'] },
                { installdeps => Path::Tiny::path( @opts{qw{install_dir domain}} )->stringify },
            ],
        );
    },

C<bin/new_config> merges what every dependant hands over, each list after the
one before, so this recipe is configured once with all of them; anything
written under C<perl> for the domain itself comes after those.  Each step is a
hash naming one of four verbs, which are F<scripts/cpan_install>'s:

    { install     => [ 'Dist::Zilla', 'Moo~>= 2.004', 'Sys::Virt@10.0.0' ] }
    { installdeps => '/opt/domains/example.test/tCMS' }
    { dzil        => '/opt/domains/example.test/checkout' }
    { pin         => { module => 'Sys::Virt', pkgconfig => 'libvirt' } }

C<install> takes anything cpanm does in place of a module name; C<installdeps>
is what the distribution in that directory says it needs; C<dzil> is what
C<dzil authordeps> and then C<dzil listdeps> say is missing there; C<pin>
installs its module at the version pkg-config reports for that package, asked
when the step runs.

The schema holds a step to that: one verb, nothing beside it, and no word with a
quote, a dollar, a backtick, a backslash or a newline in it -- any of which would
stop it reaching cpan_install as one word through a makefile line and the shell
that runs it.

=head2 When they are installed, and why then

In this recipe's own target, straight after the perl is built, in the order
they were handed over: there and then, rather than deferred.

That target runs after the fragment of every recipe that depends on this one,
because C<bin/new_config> puts a required recipe after the last recipe that
required it.  So a checkout a dependant's fragment makes is there to install
from.  And it is finished before the deferred work starts, so a service a
dependant starts in the postrun has its modules by then.  Deferred instead, they
would be queued behind whatever those dependants had already queued, the
service start included.

A step that fails stops the makefile, as a perl that fails to build does.

=cut

# A word that reaches cpan_install whole, single-quoted in a makefile line: no
# quote, dollar, backtick, backslash or newline.
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

        # user is not required, because enrich fills it in from admin_user and
        # enrich runs after validation -- a required field cannot be satisfied
        # by one.  It is always set by the time a template sees it.
        properties => {
            user => { type => 'string' },

            # No default: what goes in here is handed over by the recipes that
            # depend on this one, and cpanm, Module::Build and Dist::Zilla are
            # the build script's rather than a list anybody configures.
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

C<cpan_deps> as C<cpan_steps>: the words each step hands
F<scripts/cpan_install> after C<--notest>.

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

CPAN, which this recipe reaches three ways: perlbrew fetches the source of the
perl it builds, that perl's own C<cpan> fetches the cpanm, Module::Build and
Dist::Zilla it comes with, and cpanm fetches every C<cpan_deps> step after
that -- MetaCPAN saying which release a version pin names, and the mirrors
serving it.

=cut

sub fetch_hosts {
    return qw{www.cpan.org cpan.metacpan.org fastapi.metacpan.org};
}

1;
