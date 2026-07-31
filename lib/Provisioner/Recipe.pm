package Provisioner::Recipe;

use strict;
use warnings FATAL => 'all';

use List::Util qw{any};
use Text::Xslate;
use Text::Xslate::Bridge::TT2;

=head1 Provisioner::Recipe

=head2 SYNOPSIS

    package Provisioner::Recipe::example;
    use parent qw{Provisioner::Recipe};

    sub deps { qw{nginx-full} }
    sub validate { my ($self, %opts) = @_; return %opts; }
    sub template_files { ('example.conf.tt' => 'example.conf') }

=head2 DESCRIPTION

Base class for provisioner recipes. Provides framework for building deployment makefiles via templated fragments.

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

=head3 %opts = $recipe->validate(%opts)

Validate recipe configuration, optionally enriching it.

=cut

sub validate {
    shift;
    return @_;
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

=head3 @tests = $recipe->tests(@modules)

Array of (templated) tests to run on the remote when finished provisioning.

The list of loaded recipes is passed so you might correctly select relevant component integration tests.

=cut

sub tests {
    my @modules = @_;
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
    return !!any { -f "$_/$self->{global_template}" } @{ $self->{template_dirs} };
}

=head3 $bool = $recipe->has_template()

Returns true if a C<$recipe.tt> exists in any configured template directory.

=cut

sub has_template {
    my ($self) = @_;
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
