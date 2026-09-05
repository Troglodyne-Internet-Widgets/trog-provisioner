package Provisioner::Recipe;

#ABSTRACT: Base class for provisioner recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use List::Util qw{any};
use Text::Xslate;
use Text::Xslate::Bridge::TT2;
use Clone qw{clone};
use Scalar::Util();

use JSON::Validator::Schema::Troglodyne;

=head1 NAME

Provisioner::Recipe - Base class for the recipes: what every one of them can do, and what each has to say for itself.

=head2 SYNOPSIS

    package Provisioner::Recipe::example;
    use parent qw{Provisioner::Recipe};

    sub deps { qw{nginx-full} }
    sub validate { my ($self, %opts) = @_; return %opts; }
    sub template_files { ('example.conf.tt' => 'example.conf') }
    sub args { ( fooArg => { required => 1, default => 'bar', validator => sub {...} } }

=head2 DESCRIPTION

Provides a framework for building deployment makefiles via templated fragments.
Supports recipes that depend on other recipes, autoconfiguration and more.

A recipe is one installable thing -- a web server, a mail stack, a language
runtime -- and it answers two questions: what packages does this need, and what
does the guest have to run to end up with it configured.  C<bin/new_config>
turns the recipes named for a domain into a makefile, and C<bin/provision>
builds a guest and runs it.  What an operator writes to ask for one is described
in L<docs/CONFIGURATION.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/docs/CONFIGURATION.md>.

=head3 Naming

The last component of the package name must be lowercase --
C<Provisioner::Recipe::nginx>, never C<::Nginx>.  The makefile has uppercase
targets of its own, and the case is what keeps a recipe from colliding with one.

=head3 The fragment is a makefile, not a shell script

Each recipe renders C<templates/E<lt>nameE<gt>.tt> into a fragment of the
makefile that runs on the guest.  Write it with no leading tab; that is added
for you.  Everything else about it is make's rules rather than a shell's, and
the differences bite:

=over 4

=item * Make eats a single C<$> before the shell sees it, so a shell expansion
needs C<< $$ >>.

=item * Every line runs in its own shell, so a variable set on one line is gone
by the next, and a command spanning lines needs a C<\> on each of them.  A
heredoc cannot work at all -- render the script through C<template_files> and
install it.

=item * Recipe lines run under C</bin/sh>, which is dash on Ubuntu rather than
bash.  No brace expansion, and C<&E<gt>> is a background job and a redirect, not
a redirect of both streams.

=back

Fragments must be re-entrant, because the makefile is run with C<make -j>.  That
is what C<deps> is for: everything that has to happen before anything else is
declared up front and installed in one pass, rather than each target racing to
install its own.

=head3 Global and per-domain parts

A guest can host several domains, and some of what a recipe does is per domain
while some of it happens once for the machine.  A recipe with a
C<templates/E<lt>nameE<gt>.global.tt> gets that fragment run once no matter how
many domains are provisioned into the guest; the per-domain fragment runs for
each.  Configuration for a service with no C<conf.d> directory tends to belong
in the global half, since two domains cannot each rewrite the same file.

=head3 Conventions a recipe is expected to keep

=over 4

=item * Everything the domain owns lives under C<install_dir>, so that backing
it up is one directory.  Prepend C<install_dir> to any path a fragment names,
and symlink into it when software insists on a path of its own.

=item * Files and directories are C<0750 user:admin_user>.  C<user> is the
service account the application runs as, and defaults to the admin user -- see
C<validate>.

=item * Anything involved enough to want a shell script goes in C<scripts/>,
which is copied to the guest whole, rather than into the fragment.

=back

=head3 Order

The C<data> recipe runs first, and the rest in lexical order.  A recipe that
genuinely has to come earlier says so with an C<order> in its configuration, but
that is for things like repairing networking before anything needs it.  For
"this needs that to exist first", use C<[% script_dir %]/queue_postrun_task>
rather than ordering, which does not survive C<make -j>.

=head3 Recipes you do not intend to publish

A C<vendor/> directory in the checkout is gitignored; point the C<libdir>
parameter of a domain's configuration at it and recipes there are found like any
other.  See C<bin/new_config> for the search path.

=cut

=head2 STATIC METHODS

=head3 $class->new(%opts)

Create new recipe instance.

=cut

sub new {
    my ( $class, %opts ) = @_;

    my ($tname) = $class =~ m/^Provisioner::Recipe::(\w+)$/;
    die "Could not extract recipe name.  Recipes must be of form Provisioner::Recipe::*" unless $tname;

    $opts{template}        = "$tname.tt";
    $opts{global_template} = "$tname.global.tt";

    $opts{tt} = Text::Xslate->new(
        {
            path     => $opts{template_dirs},
            syntax   => 'TTerse',
            module   => [qw{Text::Xslate::Bridge::TT2}],
            function => { $class->formatters() },
        }
    ) || die "Could not initialize template dir";

    return bless( \%opts, $class );
}

=head2 METHODS (you will possibly want to override)

=head3 %args = $recipe->args()

Define the args of a recipe in a hash suitable toe be fed into L<JSON::Validator>'s schema() method.
Must be openapiv3.

=cut

sub args {
    my ($self) = @_;
    return ();
}

=head3 @fmts = $recipe->formatters()

Define custom template formatters available both in makefile fragments and generated files.

=cut

sub formatters {
    return ();
}

=head3 @pkgs = $recipe->deps(%recipe_config)

Define system package dependencies.  SHOULD die in the event of an unsupported platform.

=cut

sub deps {
    return ();
}

=head3 @pkgs = $recipe->dep_conflicts(%recipe_config)

Sometimes a recipe conflicts with a package from another recipe, or installed by default (postfix vs sendmail, for example).

All packages returned hereby will be removed from the dep list.

=cut

sub dep_conflicts {
    return ();
}

=head3 %required = $recipe->required_recipes(%opts)

If a recipe depends on another recipe being present, we need to build it as a synthetic recipe and append it to the list of things to provision.

Example output:

    my %out = (
        nginxproxy => sub { # returns hash, expects same %opts as validate() },
    );

The idea here is to omit having to configure dependent recipes outside of the thing depending on them.

Example usage in a recipe conf:

    tcms:
        nginxproxy: ...
        ...

This also enables automatic figuring of what to do with a dependent recipe in the event we omit mandatory options.
In some cases this will allow you to omit configuring it entirely.
This is configured by setting the sub value.

=cut

sub required_recipes {
    my ($self, %opts) = @_;

    my %limits = $self->rate_limits(%opts);
    return () unless %limits;

    # A recipe that names limits is a recipe that listens, and something has to
    # apply them.  Saying so here is what makes the dependency explicit rather
    # than ufw knowing the name of every recipe that might be installed.
    return ( ufw => sub { return ( rate_limits => \%limits ) } );
}

=head3 $merged = $recipe->reconcile($merged, $incoming)

Settle what two dependants disagreed about.

A recipe that several others depend on is configured once, out of whatever each
of them asked for.  Where two of them ask for the same field and want different
things, merging picks a side -- silently, and by an ordering nobody chose.  This
walks the two structures and hands every such collision to C<resolve_conflict>,
writing back what it decides.

Structure is somebody else's job: this only looks at fields whose values are
plain scalars in both, so nested hashes are followed into and arrays are left to
the merge.  Call it with the merged result and the contribution that has just
arrived; folding it over each contribution in turn reaches the same answer as
considering them all at once.

=cut

sub reconcile {
    my ( $self, $merged, $incoming ) = @_;
    return $merged unless ref $merged eq 'HASH' && ref $incoming eq 'HASH';
    return $self->_reconcile_into( $merged, $incoming, [] );
}

sub _reconcile_into {
    my ( $self, $merged, $incoming, $path ) = @_;

    foreach my $field ( sort keys %$incoming ) {
        my $theirs = $incoming->{$field};
        my $mine   = $merged->{$field};

        if ( ref $theirs eq 'HASH' && ref $mine eq 'HASH' ) {
            $self->_reconcile_into( $mine, $theirs, [ @$path, $field ] );
            next;
        }

        # Whatever the merge left is already one of the two, so a field only one
        # of them named needs nothing done to it.
        next if !defined $theirs || !defined $mine;
        next if ref $theirs || ref $mine;
        next if $theirs eq $mine;

        $merged->{$field} = $self->resolve_conflict( [ @$path, $field ], $mine, $theirs );
    }

    return $merged;
}

=head3 $value = $recipe->resolve_conflict($path, $mine, $theirs)

Which of two values a pair of dependants asked for this recipe to use.

C<$path> is the field they disagreed about, as an arrayref of keys from the top
of the recipe's configuration.

B<Dies by default>, naming the field and both values.  Nothing here can know
which of two configurations somebody meant, and quietly taking one is how a
guest ends up built to a configuration nobody wrote.  Overriding this is for the
cases where the recipe genuinely does know -- see C<Provisioner::Recipe::ufw>,
where two recipes listening on one port both get the higher of their limits --
and for those the override should say why it is safe.

=cut

sub resolve_conflict {
    my ( $self, $path, $mine, $theirs ) = @_;

    my $recipe = Scalar::Util::blessed($self) || $self;
    $recipe =~ s/\AProvisioner::Recipe:://;
    my $field = join( '.', @$path );

    die <<"CONFLICT";
Two recipes want different things from $recipe: $field is '$mine' to one of them and '$theirs' to another.
Nothing here can tell which you meant, so set $field explicitly under $recipe for this domain.
CONFLICT
}

=head3 %limits = $recipe->rate_limits(%opts)

The ports this recipe listens on, and the new connections a second from a single
source each should take before further ones are dropped.

Empty by default: most recipes listen on nothing, or reach the network through
something that does -- an application behind C<nginxproxy> is covered by
C<nginx>, not by itself.  A recipe that overrides this gets C<ufw> added to its
C<required_recipes> and its limits merged into that recipe's, which is where
they are turned into firewall rules.

The numbers are a threshold for abuse rather than a capacity plan: they want to
sit well above what a busy legitimate source does, since anything below that
throttles real users.  Note that this is called before validation, so read
C<%opts> with the same defaults the schema declares.

Where two recipes name a limit for the same port, the B<higher> is used -- see
C<merge_rate_limits> in C<bin/new_config>.

=cut

sub rate_limits {
    return ();
}

=head3 %opts = $recipe->validate(%opts)

Validate recipe configuration.  Enriches opts if the enrich() sub is setup for your recipe.

C<user> defaults to C<admin_user> here, so a recipe needs no C<enrich> of its own
to get one.  On a production host you generally want to set it: the service user
owns the domain's files and is what the application runs as.  When developing and
testing it is useful to have the admin and the service user be the same account,
and that is what leaving it unset gives you.

=cut

sub validate {
    my ($self, %opts) = @_;
    my %args = $self->args();

    # On a copy, all the way down.  %opts is a shallow copy, so everything
    # nested in it belongs to the caller -- and both the coercion below and any
    # enrich write through to it.  The validator turning a vhost's `ssl => 1`
    # into a JSON::PP::Boolean was enough to make the same configuration look
    # like a different one on the next render.
    %opts = %{ clone( \%opts ) };

    forget_undefs(\%opts, \%args);

    my $classname = Scalar::Util::blessed($self);

    # OpenAPIv3 coerces booleans, numbers and strings but not defaults, so
    # nothing was filling them in and every default in every args() documented
    # an intention that never happened.
    #
    # Added to what it already coerces rather than passed on its own: coerce()
    # replaces the set rather than extending it, and asking for defaults alone
    # takes booleans back out -- which turns every `type => boolean, default =>
    # 1` into "Expected boolean - got number", the default failing the check it
    # was written to satisfy.
    my $validator = JSON::Validator::Schema::Troglodyne->new;
    $validator->coerce({ %{ $validator->coerce }, defaults => 1 });
    my @errors = $validator->validate(\%opts, \%args);
    die "Had errors validating your recipe:\n".join("\n", map { "$classname$_" } @errors) if @errors;

    $opts{user} //= $opts{admin_user};

    return $self->enrich(%opts);
}

=head3 forget_undefs($opts, $schema)

Drop the fields that were named and left empty, so that the schema's default
gets a chance at them.

The validator fills in a default when the key is B<absent>, which is the right
rule for JSON and the wrong one for YAML.  Written out, a recipe says

    ntp:
        makestep:

and means "whatever you think", not "empty" -- but it arrives as an explicit
undef, which counts as present.  chronyd will not start on a C<makestep> with no
arguments after it, so the difference is not academic.

Only fields that actually declare a default are dropped.  One that does not is
left undef, because there the distinction between unset and absent may be
something a recipe cares about.

=cut

sub forget_undefs {
    my ($opts, $schema) = @_;
    return $opts unless ref $opts eq 'HASH' && ref $schema eq 'HASH';

    my $props = $schema->{properties};
    return $opts unless ref $props eq 'HASH';

    foreach my $key (keys %$props) {
        my $prop = $props->{$key};
        next unless ref $prop eq 'HASH';

        delete $opts->{$key}
          if exists $opts->{$key} && !defined $opts->{$key} && exists $prop->{default};

        forget_undefs($opts->{$key}, $prop) if ref $opts->{$key} eq 'HASH';
    }

    return $opts;
}

=head3 %opts = $recipe->enrich(%opts)

Additionally setup args based on other args passed.

=cut

sub enrich {
    my ($self, %opts) = @_;

    return %opts;
}

=head3 @dirs = $recipe->datadirs()

Directories under the domain's C<install_dir> this recipe needs to exist.

Made before the fragment runs, owned the way everything else the domain owns is
owned, so a fragment does not have to open with a run of C<mkdir -p>.

=cut

sub datadirs {
    return ();
}

=head3 %path_map = $recipe->remote_files($install_dir, $domain)

What to salvage off a guest that is already running this recipe, as a map of the
path on the guest to where it lands in the data directory.

This is how a recipe survives the guest being rebuilt: state that was generated
rather than configured -- a database dump, keys somebody accepted, a spool --
comes back down into the data directory, and goes back up when the guest is
built again.  Anything a recipe can regenerate does not belong here.

C<bin/new_config> on a cron, tarring up what it collects, is a backup strategy;
see L<docs/BACKUPS.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/docs/BACKUPS.md>.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ();
}

=head3 @files = $recipe->template_files(@loaded_recipes)

Files this recipe generates, as a map of the template under C<templates/files/>
to where it is installed relative to the domain's configuration directory.

A name that does not end in C<.tt> is copied rather than rendered, which is what
you want for something with no variables in it.  The loaded recipes are passed
in so that a recipe generating something per-service -- ufw's application
profiles, say -- can generate only what this guest actually needs.

Every file named here has to be installed by the fragment.  One that nothing
installs is dead: either it should be installed and is not, or it is a limb to
prune, and rendering it either way just leaves a file on the hypervisor that
nothing reads.

=cut

sub template_files {
    my ( $self, @recipes ) = @_;
    return ();
}

=head3 %vars = $recipe->makefile_vars()

Variables set at the top of the generated makefile, for the whole run rather
than for this recipe's fragment.

Override this when a fragment needs a value that make itself has to expand.  Do
not reach for it to pass configuration to your own templates -- that is what
C<args> and the template variables are for.

=cut

sub makefile_vars {
    return ();
}

# Global parameter validation
=head3 @tests = $recipe->tests()

Templates under C<templates/tests/> to render and run on the guest once
provisioning has finished.

These are the recipe's own account of whether it worked, and they run on the
guest because that is the only place the answer is: that the service is
listening, that the config it was given is the config it loaded, that the thing
it is supposed to serve is served.  Assert what the recipe promises rather than
what it wrote -- a test that only checks a file exists passes on a guest where
nothing started.

See L<t/TESTING.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/t/TESTING.md>.

=cut

sub tests {
    return ();
}

=head3 @pms = $recipe->testdeps(@modules)

Perl dependencies for your tests.

=cut

sub testdeps {
    my @modules = @_;
    return ();
}

=head2 Methods you probably won't want to override

=head3 $output = $recipe->render(%template_vars)

Render recipe's makefile template.

=cut

sub render {
    my ($self) = shift;
    return $self->render_file( $self->{template}, @_ );
}

=head3 $bool = $recipe->has_global_template()

Returns true if a C<$recipe.global.tt> exists in any configured template directory.

=cut

sub has_global_template {
    my ($self) = @_;
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return !!any { -f "$_/$self->{global_template}" } @{ $self->{template_dirs} };
}

=head3 $bool = $recipe->has_template()

Returns true if a C<$recipe.tt> exists in any configured template directory.

=cut

sub has_template {
    my ($self) = @_;
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return !!any { -f "$_/$self->{template}" } @{ $self->{template_dirs} };
}


=head3 $output = $recipe->render_global(%template_vars)

Render the recipe's global makefile template (C<$recipe.global.tt>).
Only call this after confirming C<has_global_template> returns true.

=cut

sub render_global {
    my ($self) = shift;
    return $self->render_file( $self->{global_template}, @_ );
}

=head3 $output = render_file($file, %template_vars)

Render specified template file.

=cut

sub render_file {
    my ( $self, $file ) = ( shift, shift );
    my %vars = $self->validated( $self->vars(), @_ );
    return $self->{tt}->render( $file, \%vars );
}

=head3 %vars = $recipe->validated(%opts)

C<validate>, B<memoized> for the life of the recipe object.

A recipe renders its fragment and then every file in C<template_files>, and each
of those was a fresh C<validate> and so a fresh C<enrich>.  Anything enrich
rewrote in place, the next call saw already rewritten.

B<One recipe object is one domain's worth of one recipe>, and the options are
whatever that domain merged for it.  C<bin/new_config> builds a recipe once per
domain and renders it once -- C<lastuniq> keeps a module from appearing twice in
a domain's list, and a dependency pulled in by several recipes accumulates their
options and is rendered once at the end.  So the first answer is the only answer
there is, and rendering the fragment, each C<template_files> entry and each test
asks for it again rather than recomputing it.

Calling this on one object with B<different> options therefore gives you the
first set's answer, and is a bug in the caller rather than a case handled here.
Where a test needs two configurations, it wants two objects, the same as
C<new_config> would build.

The memo is on the object rather than in a C<state> variable because that is
where its lifetime belongs.  C<state> in a named sub is one variable for the
sub, not one per object, so it would outlive the object it describes: a recipe
built fresh with a configuration that ought to be rejected would be answered
from the last one that validated, and the die would never happen.

=cut

sub validated {
    my ( $self, %opts ) = @_;
    $self->{_validated} //= { $self->validate(%opts) };
    return %{ $self->{_validated} };
}

=head3 %vars = vars()

Default variables for the recipe.

=cut

sub vars {
    return ();
}

1;
