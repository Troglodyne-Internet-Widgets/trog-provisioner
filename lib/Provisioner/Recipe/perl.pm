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

Sets up a .bashrc in the install_dir which includes that perl's bindir in $PATH.

Its cpanm comes from the App::cpanminus tarball, and everything else it comes
with is its C<cpan_deps>, installed through F<scripts/cpan_install>, which is
the one thing on a guest that reaches CPAN.

TODO: allow specification of version.

=head2 What other recipes install into it

C<cpan_deps> is the whole of what goes into this perl: the fleet's own
toolchain first -- C<@BASELINE>, unless C<baseline> is off -- and then what
each recipe depending on this one hands over.  One list rather than two,
because they are installed the same way and the order they are installed in is
the only thing that tells them apart.

A recipe that installs from CPAN depends on this one and hands its steps over.
tpsgi's, which is what its checkout says it needs:

    perl => sub {
        my (%opts) = @_;
        return ( cpan_deps => [ { installdeps => Path::Tiny::path( @opts{qw{install_dir domain}} )->stringify } ] );
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
when the step runs.  Any step may add C<< link => [ 'dzil' ] >>, the tools to
link into F</root/bin> once it has installed them.

The schema holds a step to that: one verb, nothing but C<link> beside it, and
no word with a quote, a dollar, a backtick, a backslash or a newline in it --
any of which would stop it reaching cpan_install as one word through a makefile
line and the shell that runs it.

=head2 When they are installed, and why then

In this recipe's own target, straight after the perl is built, in the order
they were handed over: there and then, rather than deferred.  The tools are
linked into the user's bin after all of them, by F<scripts/link_perl_tools>, so
a dzil or a starman a dependant asked for is linked on the build that installs
it rather than the next one.

That target runs after the fragment of every recipe that depends on this one,
because C<bin/new_config> puts a required recipe after the last recipe that
required it.  So a checkout a dependant's fragment makes is there to install
from.  And it is finished before the deferred work starts, so a service a
dependant starts in the postrun has its modules by then.  Deferred instead, they
would be queued behind whatever those dependants had already queued, the
service start included.

A step that fails stops the makefile, as a perl that fails to build does.

=cut

# The toolchain every guest here expects of a perl, installed ahead of what
# anything else hands over: starman has to be there before a service is started
# with it, and dzil, perlcritic and perltidy before link_perl_tools links them.
#
# Module names, spelled as CPAN's index spells them: Starman, where MetaCPAN's
# search forgave `starman`.
our @BASELINE = ( { install => [qw{Test2 Devel::NYTProf Starman Perl::Critic Perl::Tidy}] } );

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
        link => { type => 'array', items => {%WORD} },
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

            # A boolean rather than the list itself: a schema default is filled
            # in only when the key is absent, and cpan_deps is present on any
            # guest with a recipe that hands something over -- which is most of
            # them.  Defaulted there, the fleet's own toolchain would vanish
            # from exactly the guests that have the most in them.
            baseline => {
                type        => 'boolean',
                default     => 1,
                description => 'Install the toolchain every guest here expects -- Test2, Devel::NYTProf, Starman, Perl::Critic and Perl::Tidy -- ahead of everything else.  Off for a perl that is to have only what cpan_deps names.',
            },
            cpan_deps => {
                type        => 'array',
                default     => [],
                items       => \%STEP,
                description => 'What the recipes depending on this one install into it, handed over by them: see perldoc Provisioner::Recipe::perl.  Each step names one of install, installdeps, dzil or pin, and may add link.  Installed in this target after the baseline, in the order handed over.',
            },
            cpan_notest => {
                type        => 'boolean',
                default     => 1,
                description =>
                  'Skip the test suites of everything installed into this perl, the baseline and cpan_deps alike.  On by default: a guest has ninety minutes for its makefile and deferred work together, and the suites of everything a recipe like trogrunner installs do not fit.  Turn it off when what you are testing is what gets installed.  Set in _global to reach every guest, which is what the provisioning-recipes skill scratch_config --cpan-tests does.',
            },
        },
    );
}

=head2 %opts = $recipe->enrich(%opts)

C<cpan_deps>, behind C<@BASELINE> unless C<baseline> is off, as C<cpan_steps>:
the words each step hands F<scripts/cpan_install> after C<--notest>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my @steps = ( ( $opts{baseline} ? @BASELINE : () ), @{ $opts{cpan_deps} } );
    $opts{cpan_steps} = [ map { [ _words($_) ] } @steps ];
    return %opts;
}

sub _words {
    my ($step) = @_;

    my @link = map { ( '--link', $_ ) } @{ $step->{link} // [] };
    return ( @link, 'install', @{ $step->{install} } )                   if $step->{install};
    return ( @link, 'pin',     @{ $step->{pin} }{qw{pkgconfig module}} ) if $step->{pin};

    my ($verb) = grep { exists $step->{$_} } qw{installdeps dzil};
    return ( @link, $verb, $step->{$verb} );
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
