package Provisioner::Recipe;

#ABSTRACT: Base class for provisioner recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use List::Util qw{any};
use Text::Xslate;
use Text::Xslate::Bridge::TT2;
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

    return ();
}

=head3 %opts = $recipe->validate(%opts)

Validate recipe configuration.  Enriches opts if the enrich() sub is setup for your recipe.

=cut

sub validate {
    my ($self, %opts) = @_;
    my %args = $self->args();

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

Define data directories to create.

=cut

sub datadirs {
    return ();
}

=head3 %path_map = $recipe->remote_files($install_dir, $domain)

Define files to backup/restore between deployments.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ();
}

=head3 @files = $recipe->template_files(@loaded_recipes)

Define template files to process.

=cut

sub template_files {
    my ( $self, @recipes ) = @_;
    return ();
}

=head3 %vars = $recipe->makefile_vars()

Define global makefile variables.
You should override this if you need makefile vars in your recipe's makefile fragment.

=cut

sub makefile_vars {
    return ();
}

# Global parameter validation
my $validate = sub {
    my %params = @_;
    return %params;
};

=head3 @tests = $recipe->tests()

Array of (templated) tests to run on the remote when finished provisioning.

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
    my %vars = $self->validate(

        # Sane defaults
        $self->vars(),

        # Config overrides
        @_,
    );
    %vars = $validate->(%vars);
    return $self->{tt}->render( $file, \%vars );
}

=head3 %vars = vars()

Default variables for the recipe.

=cut

sub vars {
    return ();
}

1;
