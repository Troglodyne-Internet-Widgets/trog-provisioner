package Provisioner::Cookbook;

#ABSTRACT: What recipes there are, what each takes, and what a configuration for them looks like.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Clone qw{clone};
use Cwd();
use File::Basename();
use File::Find();
use List::Util qw{any uniq};
use Provisioner::Utils();
use File::Slurper();
use File::Slurper::Temp();
use File::Temp();
use Hash::Merge();
use JSON::Validator::Schema::Troglodyne;
use YAML::XS();

use Trog::Config();
use Trog::Secrets();

=head1 NAME

Provisioner::Cookbook - what recipes there are, what each takes, and what a
configuration for them looks like before anybody fills it in.

=head1 SYNOPSIS

    use Provisioner::Cookbook();

    my @all = Provisioner::Cookbook->names();
    my %spec = Provisioner::Cookbook->spec('mariadb');

    my ($config, @todo) = Provisioner::Cookbook->scaffold('mariadb');
    # $config: { version => 'CHANGEME', root_pw => 'CHANGEME', ... }
    # @todo:   qw{mariadb.dumpfile mariadb.root_pw mariadb.version}

=head1 DESCRIPTION

Every recipe declares what it takes in C<args()>, an OpenAPIv3 object schema.
From those declarations alone, this module answers three questions: which recipes
exist, what each one accepts, and what the smallest working configuration is.

F<bin/recipes> answers the first two and F<bin/new_guest> answers the third.
Both are this module with a command line.

L<Provisioner::Recipe> defines what a recipe is.  This module lists the
recipes.  It is not under F<Provisioner/Recipe/>, because the code discovers
and loads everything there as a recipe.

=head1 CLASS METHODS

=head2 recipe_dir

Returns the directory that holds the recipe modules.  It is found relative to
this file, so a checkout and an installed dist give the same answer.

=cut

sub recipe_dir { return File::Basename::dirname(__FILE__) . '/Recipe' }

=head2 template_dir

Returns the template directory.  It is found relative to this file, for the
same reason as C<recipe_dir>.

=cut

sub template_dir { return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../templates' ) }

=head2 template_dirs($distro, @libdirs)

Returns an array reference of the template search path for a build, in the
order that a renderer tries it.

The directory for a distribution comes before the generic one.  So
F<templates/ubuntu/nginx.tt> wins over F<templates/nginx.tt>, because the
renderer finds it first.  No other code knows about this order.  Every fragment
today is written for apt and systemd, so it lives under F<ubuntu/>.
F<templates/> holds what is truly shared: F<makefile.tt> and most of F<files/>
and F<tests/>.

Each vendor F<libdir> comes after the checkout, in the same pattern.  A vendor
recipe adds to what ships here and does not override it.

The distribution's directory is the one its recipe names in C<template_subdir>.
That recipe looks up its own generated files there as well, so the two cannot
name different directories.  C<$distro> has to name a distro recipe.

=cut

sub template_dirs {
    my ( $class, $distro, @libdirs ) = @_;

    my $subdir = $distro ? $class->load($distro)->template_subdir : undef;
    my @bases  = ( $class->template_dir, map { "$_/templates" } @libdirs );
    return [ map { ( ( $subdir ? "$_/$subdir" : () ), $_ ) } @bases ];
}

=head2 names

Returns, sorted, the name of every recipe that a domain can be built with.
Dies if the recipe directory does not exist.

This leaves out the recipes that direct a build and do not take part in it,
because nobody writes one under a domain.  See C<directors>.

=cut

sub names {
    my ($class) = @_;

    my $dir = $class->recipe_dir;
    die "Could not read $dir\n" unless -d $dir;

    my %director = map { $_ => 1 } $class->directors();
    return grep { !$director{$_} }
      map { m/\A(\w+)\.pm\z/ ? $1 : () } Provisioner::Utils::files_in($dir);
}

=head2 fetch_hosts

Returns every host that any recipe names in C<fetch_hosts>, sorted and without
duplicates.  L<Provisioner::Recipe::fetchcache> uses these hosts by default.

This loads every recipe, which C<names> does not.  It asks once per process,
because the answer is a fact about the code.

=cut

sub fetch_hosts {
    my ($class) = @_;

    state @hosts = List::Util::uniq( sort map { $class->load($_)->fetch_hosts } $class->names );
    return @hosts;
}

=head2 @refs = secret_references()

Every C<secret:> reference this installation asks the store for, sorted and
without duplicates.  Three kinds go in:

=over 4

=item * What the configuration writes down, at any depth, which
L<Trog::Secrets/needed> finds.

=item * What each recipe of each domain places from the store, which its
C<guest_secrets> names.

=item * The key of each configured domain, which opens the guest and which
L<Trog::Guest/ref_for_key> names.

=back

F<bin/forget_secret> asks so that it can refuse to delete one that is still
wanted, and F<bin/regroup_secrets> asks so that it knows which group each entry
belongs in.  Neither can work it out from the store itself: an entry says what
it is called, not who reads it.

A recipe this installation does not have is skipped rather than fatal, as in
C<configured_fetch_hosts>.

=cut

sub secret_references {
    my ($class) = @_;

    my $conf   = $class->configuration();
    my %needed = Trog::Secrets->needed($conf);

    my @refs = values %needed;

    foreach my $domain ( grep { $_ ne '_base' } sort keys %$conf ) {
        my $config  = $class->domain_config( $domain, $conf );
        my $install = $class->install_dir( $domain, $conf );

        # Not a use at the top: Trog::Guest loads Net::OpenSSH::More, which
        # loads File::HomeDir in a BEGIN block, which stats the filesystem
        # looking for xdg-user-dir.  Every test that mocks the filesystem loads
        # this module, and an unmocked stat is fatal there.
        require Trog::Guest;
        push( @refs, Trog::Guest->ref_for_key($domain) );

        foreach my $recipe ( sort keys %$config ) {
            next unless $class->has($recipe);

            my %placed = eval { $class->load($recipe)->guest_secrets( $install, $domain, %{ $config->{$recipe} // {} } ) } or next;
            push( @refs, map { $_->{ref} } grep { ref eq 'HASH' && $_->{ref} } values %placed );
        }
    }

    return uniq( sort grep { $_ } @refs );
}

=head2 configured_fetch_hosts

Returns every host that the configured domains of this installation download
from, sorted and without duplicates.  Each recipe of a domain is asked
C<fetch_hosts> with the configuration of that domain.

C<fetch_hosts> above cannot give this answer, because it asks the class with no
configuration.  So a recipe with a configured upstream names only its default
host.  Examples are C<repo_url> in koan and trogrunner, and C<api_url> in
admincode.  The C<upstreams> of L<Provisioner::Recipe::fetchcache> default to this
list together with C<fetch_hosts>.  So the cache also answers for a host that
only a F<recipes.d> entry names.

Dies if a recipe cannot say which hosts a domain fetches from.

This method does not cache its answer.  C<configuration> already remembers
each file by path.  A second cache with a different lifetime goes stale under a
test that points C<TROG_PROVISIONER_CONFIG> at a different place.

=cut

sub configured_fetch_hosts {
    my ($class) = @_;

    my $conf = $class->configuration();
    my @hosts;

    # _base holds what every domain gets, and it is not a guest of its own.
    foreach my $domain ( grep { $_ ne '_base' } sort keys %$conf ) {
        my $config = $class->domain_config( $domain, $conf );

        foreach my $recipe ( sort keys %$config ) {

            # Other code reports a recipe that this installation does not have.
            # Here it is not a reason to fetch nothing.
            next unless $class->has($recipe);
            eval { push( @hosts, $class->load($recipe)->fetch_hosts( %{ $config->{$recipe} // {} } ) ); 1 } or do {
                die "The $recipe recipe could not say which hosts $domain fetches from: $@";
            };
        }
    }

    return List::Util::uniq( sort grep { $_ } @hosts );
}

=head2 cache_classes

Returns every cache class that any recipe declares, as a list of C<{ class
=E<gt> ..., pattern =E<gt> ... }>.  L<Provisioner::Recipe::fetchcache> uses
them to decide how long it keeps a file.

This asks every recipe, not only the recipes of one domain, because the cache
serves the whole fleet.  It asks once per process.

=cut

sub cache_classes {
    my ($class) = @_;

    state @classes = map { $class->load($_)->cache_classes } $class->names;
    return @classes;
}

=head2 implementations($interface)

Returns, sorted, the recipes whose class C<isa> C<$interface>.  For example,
C<Provisioner::DNSRecipe> has two: C<pdns> and C<registrar>.

This loads every recipe, which C<names> does not.  It asks once per process for
each interface, because inheritance is a fact about the code.

C<resolve_substitutable_dependency> uses this.  With it, a recipe can ask for
something that answers a dns-01 challenge without naming the recipe that does
it.

=cut

sub implementations {
    my ( $class, $interface ) = @_;

    # Directors too, because names() leaves them out, and every
    # Provisioner::DistroRecipe is a director.
    state %by_interface;
    $by_interface{$interface} //= [
        sort grep {
            eval { $class->load($_)->isa($interface) }
        } ( $class->names, $class->directors )
    ];

    return @{ $by_interface{$interface} };
}

=head2 directors

Returns the recipes that direct a build and do not run in one: C<vm>, and the
distro recipe of each distribution that has a namespace.

They are recipes in all other ways.  They declare C<args>, F<recipes.yaml>
configures them, and C<bin/recipes> prints their schema.  But nobody names one
under a domain, just as nobody names the hypervisor there.  So C<names> leaves
them out.  C<has> and C<load> still answer for them.

The list comes from names, not from C<is_module> on each module, because
C<names> loads nothing.  C<abstract> reads the file for the same reason.
C<t/recipes.t> makes sure that the two answers agree.

=cut

sub directors {
    my ($class) = @_;
    return ( 'vm', $class->distros() );
}

=head2 distros

Returns, sorted and in lower case, the distributions that have recipes.  These
are the values that C<distro> in the C<_global> block of a domain can take.

There is one for each subdirectory of the recipe directory.  C<Recipe/Ubuntu/>
holds the specializations for Ubuntu, and C<Recipe/ubuntu.pm> is the distro
recipe itself.  The list comes from the directory, so to add a distribution you
add files.

=cut

sub distros {
    my ($class) = @_;
    my @distros = sort map { lc } Provisioner::Utils::dirs_in( $class->recipe_dir );
    return @distros;
}

=head2 has($name)

Returns true if there is a recipe named C<$name>.  A name that is not a single
word is never a recipe.

=cut

sub has {
    my ( $class, $name ) = @_;
    return 0 unless defined $name && $name =~ m/\A\w+\z/;

    my $path = $class->recipe_dir . "/$name.pm";
    return -f $path;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether there is one is the whole question; load() opens it for itself
}

=head2 load($name, %opts)

Loads the recipe C<$name> and returns its class name.

Dies if there is no recipe by that name, and points to C<bin/recipes> for the
list.  A typo is the likeliest reason for a bad name.  Also dies if the module
does not inherit from L<Provisioner::Recipe>.

C<distro> asks for the specialization of the recipe for that distribution, for
example C<Provisioner::Recipe::Ubuntu::nginx> in place of
C<Provisioner::Recipe::nginx>.  This is how a build chooses its package names.
A recipe with no specialization for that distribution comes back as itself.
Most recipes install nothing, and a shared C<deps> stays shared.

Only a missing specialization falls back to the recipe itself.  If the file
exists, this C<require>s it with no C<eval>, so a specialization that does not
compile stops the run.  With a fallback, a typo in F<Ubuntu/mail.pm> gives a
guest without postfix, and nothing says why.  For the same reason, this dies if
the specialization does not inherit from the recipe.  Otherwise a subclass that
forgot its C<parent> inherits an empty C<deps> and quietly installs nothing.

=cut

sub load {
    my ( $class, $name, %opts ) = @_;

    die "No recipe named '" . ( $name // '' ) . "'.\n" . "Try `bin/recipes` for the ones there are.\n"
      unless $class->has($name);

    my $module = "Provisioner::Recipe::$name";
    require "Provisioner/Recipe/$name.pm";    ## no critic (Modules::RequireBarewordIncludes)

    die "$module loaded but is not a Provisioner::Recipe\n"
      unless $module->isa('Provisioner::Recipe');

    return $module unless defined $opts{distro} && $opts{distro} =~ m/\A\w+\z/;

    my $namespace = ucfirst lc $opts{distro};
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return $module unless -f $class->recipe_dir . "/$namespace/$name.pm";

    my $specific = "Provisioner::Recipe::${namespace}::$name";
    require "Provisioner/Recipe/$namespace/$name.pm";    ## no critic (Modules::RequireBarewordIncludes)

    die "$specific loaded but is not a $module.  A distro's version of a recipe has to\ninherit from it -- add `use parent qw{$module}`.\n"
      unless $specific->isa($module);

    return $specific;
}

=head2 abstract($name)

Returns the one-line description from the C<#ABSTRACT> line of the recipe, or
undef if there is none.  Dies if it cannot close the file.

It reads the file and does not load the module.  So a list of every recipe
costs one open for each recipe and no module loads.

=cut

sub abstract {
    my ( $class, $name ) = @_;

    my $path = $class->recipe_dir . "/$name.pm";
    open( my $fh, '<', $path ) or return undef;
    while ( my $line = <$fh> ) {
        next unless $line =~ m/\A\s*[#]\s*ABSTRACT:\s*(\N+?)\s*\z/;
        my $abstract = $1;
        close($fh) or die "Could not close $path: $!\n";
        return $abstract;
    }
    close($fh) or die "Could not close $path: $!\n";
    return undef;
}

=head2 spec($name, %opts)

Returns the C<args()> schema of the recipe C<$name>, as a hash.  Dies as
C<load> does.

C<args()> is an instance method, and C<validate> calls it on an object.  A
recipe can compute a default from C<$self>.  So this calls C<args()> on an
object and not on the class name.  C<%opts> become the fields of that object.

C<output_dir> defaults to one scratch directory for the process, which is
removed at exit.  At least one recipe generates a secret and writes it there
when it is asked what it takes.  A description of a recipe must not leave files
in the current directory.

A recipe can do real work here.  The garage recipe asks GitHub for the current
release to use as its version default.  So C<spec('garage')> makes a network
request and takes as long as that request.

=cut

sub spec {
    my ( $class, $name, %opts ) = @_;

    my $module = $class->load($name);

    state $scratch;
    $opts{output_dir} //= ( $scratch //= File::Temp::tempdir( CLEANUP => 1 ) );

    return bless( \%opts, $module )->args();
}

=head2 properties($spec)

Returns the C<properties> hash of an object schema, or an empty hash if
C<$spec> has none.

It reads only C<properties>, which is the name that OpenAPIv3 uses and that the
validator reads.  A schema that spells it C<parameters> gets an empty hash
here.  A scaffold that offered those fields claims that the recipe checks
something that it does not check.  F<t/Provisioner-Cookbook.t> fails on any
recipe that spells it C<parameters>.

=cut

sub properties {
    my ( $class, $spec ) = @_;
    return {} unless ref $spec eq 'HASH';
    return ref $spec->{properties} eq 'HASH' ? $spec->{properties} : {};
}

=head2 defaults($name, %opts)

Returns the defaults that the schema of recipe C<$name> declares, as a hash of
field to value.  C<%opts> go to C<spec>.

This is for a caller that fills in a field itself and does not let the
validator do it.  C<bin/new_config> writes F<provision.conf>, and
C<bin/new_guest> writes a domain block.  With this, the value that they write is
the value that the recipe uses.

It returns only top-level fields that declare a default.  A nested default
belongs to the object that declares it, and the validator applies it.  See
L<Provisioner::Recipe/args>.

=cut

sub defaults {
    my ( $class, $name, %opts ) = @_;

    my $props = $class->properties( { $class->spec( $name, %opts ) } );
    return map { exists $props->{$_}{default} ? ( $_ => $props->{$_}{default} ) : () } keys %$props;
}

=head2 PLACEHOLDER

Returns the value for a required field that has no default: the string
C<CHANGEME>.

It is an obvious string on purpose.  A required boolean filled in with a
plausible C<0> provisions quietly and wrongly.  This string fails validation of
a boolean, and the error names the key.

=cut

sub PLACEHOLDER { return 'CHANGEME' }

=head2 scaffold($name, %opts)

Returns the smallest configuration for recipe C<$name> that can work, and a
list of the dotted paths in it that a person still has to fill in.  Dies as
C<spec> does.

    my ($config, @todo) = Provisioner::Cookbook->scaffold('mariadb');

A required field gets its default if the recipe has one, and C<PLACEHOLDER> if
not.  Other fields are left out, so the defaults of the recipe keep applying and
are not frozen into the generated file.

C<all> also includes the optional fields, with their defaults where they have
them.  Use it when you intend to edit the full list anyway.

C<provided> is configuration that comes from somewhere else, usually the
C<_base> block of F<recipes.yaml>.  Its fields are left out and are not
reported as missing.  A request for a value that is already supplied makes a
generated file pin fields that nobody meant to pin.

C<output_dir> goes to C<spec>.

The configuration is undef for a recipe that needs nothing.  The configuration
files spell that as a bare C<nosnap:> with nothing under it.

=cut

sub scaffold {
    my ( $class, $name, %opts ) = @_;

    my %spec = $class->spec( $name, output_dir => $opts{output_dir} );
    my ( $config, @todo ) = $class->_scaffold_object( \%spec, $name, \%opts );

    return ( undef,   @todo ) unless ref $config eq 'HASH' && %$config;
    return ( $config, @todo );
}

sub _scaffold_object {
    my ( $class, $spec, $path, $opts ) = @_;

    my $props    = $class->properties($spec);
    my %required = map { $_ => 1 } @{ $spec->{required} // [] };

    my $provided = ref $opts->{provided} eq 'HASH' ? $opts->{provided} : {};

    my ( %out, @todo );
    foreach my $key ( sort keys %$props ) {
        my $prop = $props->{$key};
        next unless ref $prop eq 'HASH';

        next if exists $provided->{$key};

        # The build fills in a readOnly field, so an operator writes nothing
        # there.
        next if $prop->{readOnly};

        my $wanted = $required{$key} || $opts->{all};
        next unless $wanted;

        my ( $value, @sub ) = $class->_scaffold_value(
            $prop, "$path.$key",
            { %$opts, provided => $provided->{$key} }
        );
        next unless defined $value;

        $out{$key} = $value;
        push @todo, @sub;
    }

    return ( \%out, @todo );
}

sub _scaffold_value {
    my ( $class, $prop, $path, $opts ) = @_;

    return ( clone( $prop->{default} ), () ) if exists $prop->{default};

    my $type = $prop->{type} // '';

    if ( $type eq 'object' ) {

        # An object with only additionalProperties has nothing to scaffold.  It
        # is left out, unless it must have a property, and then a person must
        # choose one.
        my ( $sub, @todo ) = $class->_scaffold_object( $prop, $path, $opts );
        return ( $sub,                @todo ) if %$sub;
        return ( $class->PLACEHOLDER, $path ) if ( $prop->{minProperties} // 0 ) > 0;
        return ( undef,               () );
    }

    if ( $type eq 'array' ) {
        my ( $item, @todo ) = $class->_scaffold_value( $prop->{items} // {}, "$path\[0]", $opts );
        return ( [],      () ) unless defined $item;
        return ( [$item], @todo );
    }

    return ( $class->PLACEHOLDER, $path );
}

=head2 scaffold_dependencies(\@named, %opts)

Returns a hash reference of the blocks that a domain needs for recipes that
nobody named, and the dotted paths in them that a person still has to fill in.

    my ( $blocks, @todo ) = Provisioner::Cookbook->scaffold_dependencies( ['grafanasyslog'] );

C<scaffold> answers for one recipe, and C<bin/new_guest> asks it about each
recipe on its command line.  That is not the full set that the guest is built
from.  C<bin/new_config> adds each dependency from C<required_recipes>, so a
recipe that nobody named can arrive with required fields of its own.  The
recipe that asked for it usually supplies them.  When it cannot, a person must
know.  For example, C<grafana> wants an C<admin_password>, and a dependent
recipe cannot choose a password for the operator.  Without this, the report
says that there is nothing to fill in.  Then C<bin/new_config> refuses the
configuration when the guest is already going up.

Only dependencies that still want a value come back.  The depsolver adds the
recipe either way, so a block here is a place to put a value, not a request for
the recipe.

C<base> is the C<_base> block and C<global_config> is the C<_global> block, as
F<recipes.yaml> lays them out.  C<domain> is required, as in
C<resolve_dependencies>.  C<all> and C<output_dir> go to C<scaffold>.

A key that names an interface is resolved against the C<base> blocks of the
named recipes only, because the full configuration of the domain is not
available here.  Dies as C<resolve_dependencies> does, which includes a
C<required_recipes> sub that cannot answer without the global configuration.

=cut

sub scaffold_dependencies {
    my ( $class, $named, %opts ) = @_;

    my $base   = ref $opts{base} eq 'HASH'          ? $opts{base}          : {};
    my $global = ref $opts{global_config} eq 'HASH' ? $opts{global_config} : {};
    my $distro = $global->{distro} // 'ubuntu';

    # Worked out here and not asked of the caller, because bin/new_guest does
    # not know which packager a distribution uses.
    # One scratch directory for the process, as in spec(), because nothing here
    # writes to it.
    state $scratch;
    my %provisioner = (
        distro          => $distro,
        target_packager => $class->load($distro)->packager,
        template_dirs   => $class->template_dirs($distro),
        output_dir      => $opts{output_dir} // ( $scratch //= File::Temp::tempdir( CLEANUP => 1 ) ),
    );

    # One entry for each named recipe.  The walk merges what each dependency
    # contributes into these.
    my %domain_conf = map { $_ => clone( $base->{$_} // {} ) } @$named;

    my ( $modules, $builders ) = $class->resolve_dependencies(
        modules       => [@$named],
        domain_conf   => \%domain_conf,
        global_config => $global,
        distro        => $distro,
        provisioner   => \%provisioner,
        domain        => $opts{domain},
    );

    # The caller already scaffolded the recipes it named.
    my %named = map { $_ => 1 } @$named;

    my ( %blocks, @todo );
    foreach my $dep (@$modules) {
        next if $named{$dep};
        next unless $builders->{$dep}->is_module;

        my ( $config, @needed ) = $class->scaffold(
            $dep,
            all        => $opts{all},
            output_dir => $opts{output_dir},
            provided   => { %{ $domain_conf{$dep} // {} }, %{ $base->{$dep} // {} } },
        );
        next unless @needed;

        $blocks{$dep} = $config;
        push @todo, @needed;
    }

    return ( \%blocks, @todo );
}

=head2 placeholders_in($config, $path)

Returns every place in C<$config> that still holds C<PLACEHOLDER>, as dotted
paths, with a list item as C<[n]>.  C<$path> is the prefix for those paths, and
is empty by default.

A placeholder is a valid string, so nothing downstream rejects it.
C<root_pw: CHANGEME> validates, provisions, and gives a database whose root
password is CHANGEME.  So a person must look, and this method finds what to
look at.

=cut

sub placeholders_in {
    my ( $class, $config, $path ) = @_;
    $path //= '';

    my $ref = ref $config;

    if ( $ref eq 'HASH' ) {
        return map { $class->placeholders_in( $config->{$_}, $path eq '' ? $_ : "$path.$_" ) }
          sort keys %$config;
    }
    if ( $ref eq 'ARRAY' ) {
        return map { $class->placeholders_in( $config->[$_], "$path\[$_]" ) } 0 .. $#$config;
    }

    return ($path) if defined $config && !$ref && $config eq $class->PLACEHOLDER;
    return ();
}

=head2 resolve_substitutable_dependency(%args)

Returns the recipe that satisfies a substitutable dependency.  A substitutable
dependency names an interface that several recipes can answer for, not a
recipe.

The interface decides, through its C<implementation_for>.  This method asks it
and does not work out the answer again.  Both callers, this one and a recipe
that renders its own templates, ask the interface.  So the rules stay in one
place.

This method adds what the interface cannot know.  The answer must be a recipe
that this installation has, and that implements the interface.  A
configuration that names another recipe is a typo, and this says so before
anything loads it.

C<interface> is the interface that was named.  C<domain> is the domain that
names it, and it is required.

C<domain_conf> is the configuration of the domain itself.  C<host_conf> is the
configuration of the machine that the domain is layered onto.  C<host> names
that machine, so a refusal can say which guest it looked at.  Both are undef
for a domain with a guest of its own.

C<requiring_conf> is the configuration of the recipe that declared the
dependency.  The interface names the key that holds a preference, and reads it
from there.  So a domain settles a tie in the block where it already configures
that recipe.

Dies if C<domain> is missing, if the interface does not load, if no recipe
implements it, or if the interface chooses a recipe that does not implement it.

=cut

sub resolve_substitutable_dependency {
    my ( $class, %args ) = @_;
    my ( $interface, $domain_conf, $host_conf, $requiring_conf, $domain, $host ) = @args{qw{interface domain_conf host_conf requiring_conf domain host}};

    # Every refusal below names the domain.
    die "resolve_substitutable_dependency needs the domain asking; pass one.\n" unless $domain;

    # The name comes from required_recipes as text, so nothing loaded the
    # interface yet.
    my $path = $interface =~ s{::}{/}gr;
    eval { require "$path.pm"; 1 } or die "$domain depends on $interface, which will not load: $@";    ## no critic (Modules::RequireBarewordIncludes)

    my @known = $class->implementations($interface);
    die "$domain depends on $interface, which no recipe here implements.\n" unless @known;

    # Pass the configuration of this run, not of the installation.  The two
    # differ for every scratch run, and the resolver cannot tell which is meant.
    my $chosen = $interface->implementation_for(
        %{ $requiring_conf // {} },
        domain          => $domain,
        configured      => $domain_conf // {},
        host            => $host,
        host_configured => $host_conf,
    );

    die "$domain resolves $interface to '$chosen', which is not one of the recipes that implement it (" . join( ', ', @known ) . ").\n"
      unless List::Util::any { $_ eq $chosen } @known;

    return $chosen;
}

=head2 resolve_dependencies(%args)

Adds to the module list of a domain everything that its recipes require, and
configures what that adds.

    my ( $modules, $builders ) = Provisioner::Cookbook->resolve_dependencies(
        modules       => [ $distro_name, sort keys %{ $conf->{$domain} } ],
        domain_conf   => $conf->{$domain},
        global_config => \%global,
        distro        => $distro_name,
        provisioner   => \%provisioner_opts,
        domain        => $domain,
    );

A recipe names what it needs in C<required_recipes>, and each dependency can
need more.  So the list is walked while it grows, not once.  Each dependency is
added and configured from what the recipes that depend on it asked for.  Where
two of them asked for different values, the dependency C<reconcile>s them.

Returns an array reference of the expanded list, and a hash reference of the
builders that it made, keyed by recipe name.  Reuse the builders, so that
nothing loads every recipe a second time.  C<domain_conf> changes in place.
The configuration of each dependency becomes the merge of what the domain wrote
and what each dependent gave it.

The list comes back in build order.  A dependency is added again each time
something requires it.  The last mention counts, because the dependency must
run after everything that requires it.  So the list goes through C<lastuniq>
before it returns.  L<Provisioner::Recipe/is_module> says which entries are
modules, and the caller filters them.

C<domain> is required, and this dies without it.  Do not cover a missing domain
with a default.  A caller with no real domain must knowingly supply a made-up
one.

C<host_conf> and C<host> go to C<resolve_substitutable_dependency>.

=head3 Two sources, on purpose

The dependencies come from the C<required_recipes> of the base class and from
the C<required_recipes> of the recipe.  This calls the base class version
directly, not through the recipe.  The base class decides what every recipe
owes: C<ufw> its rate limits, and C<data> its restores.  An override that does
not call C<SUPER> must not drop those, and many overrides do not call it.

=head3 When a recipe cannot say what it wants

A C<required_recipes> sub gets the global configuration and the configuration
of the requiring recipe, and reads both.  For example, C<tcms> builds a path
from C<install_dir> and C<domain>.  The sub always gets those two.  C<domain> is
the domain that this was called for.  If C<_global> names no C<install_dir>,
the sub gets the default of the C<install_dir> method.  A value in
C<global_config> takes precedence.

A sub that reads any other global dies without it, and its message is about
what it was building, not about a configuration.  So this dies with a message
that names the recipe that did not answer and the dependency it was asked
about.  That configuration comes from C<_global> in F<recipes.yaml>.  A caller
without it has a file to fix, not a dependency to skip.

=cut

sub resolve_dependencies {
    my ( $class, %args ) = @_;

    my @modules       = @{ $args{modules} // [] };
    my $domain_conf   = $args{domain_conf}   // {};
    my $global_config = $args{global_config} // {};
    my $distro        = $args{distro};
    my $provisioner   = $args{provisioner} // {};

    # Every refusal below names the domain.
    my $domain = $args{domain}
      or die "resolve_dependencies needs the domain being provisioned; pass one, bogus if that is what the caller has.\n";

    # What every required_recipes sub is handed.  The domain and install_dir
    # are there even when the caller's _global has neither, because no file can
    # name the domain, and install_dir has a default.  A value in _global wins.
    my %given = (
        domain      => $domain,
        install_dir => $class->install_dir( $domain, {} ),
        %$global_config,
    );

    my $depmod_conf = {};
    my %builders;

    # The configuration of each recipe as the domain wrote it, taken on the
    # first visit.  A recipe is visited once for each recipe that depends on
    # it, and each visit merges into this copy.  Hash::Merge appends lists, so a
    # merge into the result of the previous visit repeats a list once per visit.
    my %as_written;

    # A C-style loop reads the length of @modules on each pass, so it also
    # visits the dependencies that the walk pushes onto the list.  A foreach
    # must not see its array change.
    for ( my $i = 0; $i < scalar(@modules); $i++ ) {
        my $module  = $modules[$i];
        my $builder = $builders{$module} //= $class->load( $module, distro => $distro )->new(%$provisioner);

        my $pconf = $domain_conf->{$module} // {};

        # The base class first, then the recipe.  See L</Two sources, on purpose>.
        my %dep_recipes = (
            Provisioner::Recipe::required_recipes( $builder, %given, %$pconf ),
            $builder->required_recipes( %given, %$pconf ),
        );

        # Sorted, so that two identical provisions produce the same makefile.
        # Hash order is per process, so without this the targets come out in a
        # different sequence every run.  It does not touch the ordering rule:
        # each dependency is still appended after the recipe that named it.
        foreach my $required ( sort keys(%dep_recipes) ) {

            # A substitutable dependency names an interface.  Resolve it to a
            # recipe here, because has() accepts only \w+, and the code below
            # loads the name and puts it in the module list.
            if ( index( $required, '::' ) >= 0 ) {
                my $chosen = $class->resolve_substitutable_dependency(
                    interface      => $required,
                    domain_conf    => $domain_conf,
                    host_conf      => $args{host_conf},
                    requiring_conf => $pconf,
                    domain         => $domain,
                    host           => $args{host},
                );
                $dep_recipes{$chosen} //= $dep_recipes{$required};
                delete $dep_recipes{$required};
                $required = $chosen;
            }

            my $manual_args = delete $pconf->{$required} // {};

            # A sub computes the options for the dependency.  Options that the
            # domain wrote for it take precedence.
            my %depargs;
            if ( ref $dep_recipes{$required} eq 'CODE' ) {
                my $said;
                my $answered = eval { %depargs = $dep_recipes{$required}->( %given, %$pconf ); 1 };
                $said = $@ unless $answered;
                die "$domain: the $module recipe could not say what it wants from $required.\n" . "It said: $said" . "A required_recipes sub reads the global configuration it is handed, so this is usually one of those missing.  Those come from _global in recipes.yaml.\n"
                  unless $answered;
            }
            my %cur_args = %$manual_args ? ( $required => $manual_args ) : ( $required => \%depargs );

            # Push it each time something names it.  lastuniq keeps the last
            # mention, which puts a dependency after everything that requires it.
            push( @modules, $required );
            $depmod_conf = $class->_dep_merger->merge( $depmod_conf, \%cur_args );

            # Hash::Merge picks a side where two dependents disagree.  Only the
            # required recipe knows which side is right, so it is asked, and it
            # dies if it does not know.
            $class->load( $required, distro => $distro )->reconcile( $depmod_conf->{$required}, $cur_args{$required} );
        }

        # Merge in what every dependent asked of this recipe.
        $as_written{$module} //= clone($pconf);
        if ( $depmod_conf->{$module} ) {
            $domain_conf->{$module} = $class->_dep_merger->merge( $depmod_conf->{$module}, $as_written{$module} );

            # Also compare what the operator wrote for this recipe with what
            # its dependents asked for.
            $builder->reconcile( $domain_conf->{$module}, $_ ) for ( $depmod_conf->{$module}, $as_written{$module} );
        }
    }

    return ( [ Provisioner::Utils::lastuniq(@modules) ], \%builders );
}

# Two merges that want opposite things, so two mergers.  Each is an object, so
# a process-wide Hash::Merge behavior set elsewhere cannot change it.
#
# _base holds defaults and a domain overrides them, so that merge keeps the
# right.  See domain_config().
#
# The file merge keeps the left on purpose.  The file of a domain adds to
# recipes.yaml and does not override it.  See configuration().
sub _base_merger { state $merger = Hash::Merge->new('RIGHT_PRECEDENT');   return $merger }
sub _file_merger { state $merger = Hash::Merge->new('STORAGE_PRECEDENT'); return $merger }

# The merger of the depsolver, for the two merges that collect what several
# recipes ask of a shared dependency.  An object, for the reason above.
#
# It keeps the left on purpose.  These merges build the options of a dependency
# one requester at a time.  Where two requesters disagree, reconcile sees both
# sides and settles it.
sub _dep_merger { state $merger = Hash::Merge->new('STORAGE_PRECEDENT'); return $merger }

=head2 configuration($path)

Returns the recipe configuration of an installation as a hash reference, keyed
by domain.  It is F<recipes.yaml>, with each F<recipes.d/*.yaml> next to it
merged in.  C<$path> defaults to the F<recipes.yaml> in the directory of
L<Trog::Config>.  If that file does not exist, this returns an empty
configuration.  Dies if a file is not valid YAML.

The file of a domain adds to the main file and does not override it.  Where
both files set a key, the value from F<recipes.yaml> stays.  This ignores
C<_base> and C<_shared> in the files of a domain, because one guest does not
decide what every guest gets.

It reads each file once and remembers the result.  Nobody edits the
configuration under a command that is already running on it.

=cut

# Keyed by resolved path, so two installations give two answers, and a second
# read of one file does no work.
my %CONFIGURATION;

sub configuration {
    my ( $class, $path ) = @_;
    $path //= Trog::Config->path('recipes.yaml');

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    return {} unless -f $path;

    my $key = Cwd::abs_path($path);
    return $CONFIGURATION{$key} if $CONFIGURATION{$key};

    my $conf = YAML::XS::Load( File::Slurper::read_binary($path) );

    my $merger = _file_merger();
    my $extra  = File::Basename::dirname($key) . '/recipes.d';
    File::Find::find(
        {
            wanted => sub {
                my $file = $_;
                ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
                return unless -f $file && $file =~ m/\.yaml$/;

                my $domain = YAML::XS::Load( File::Slurper::read_binary($file) );
                delete $domain->{$_} for qw{_base _shared};

                $conf = $merger->merge( $conf, $domain );
            },
            no_chdir => 1,
            bydepth  => 1,
        },
        $extra
    ) if -d $extra;

    return $CONFIGURATION{$key} = $conf;
}

=head2 remember($path, $conf)

Stores a copy of C<$conf> as the configuration for C<$path>.  After this, every
request for that configuration gets this copy.  C<$path> defaults as in
C<configuration>.

It has one caller, for one reason.  C<bin/new_config> reads the configuration,
clones it, and resolves every C<secret:> reference in the clone.  The copy that
C<configuration> remembers still says C<secret:group/entry/field>.  Without
this, a recipe that reads the configuration of a sibling through
C<domain_config> gets the reference and not the secret.

It keys by path in the same way as C<configuration>, so both agree on the file.
C<forget> clears it.

=cut

sub remember {
    my ( $class, $path, $conf ) = @_;

    my $key = Cwd::abs_path( $path // Trog::Config->path('recipes.yaml') );

    # A copy, because the caller keeps using its own.  bin/new_config deletes
    # _base from its copy, and every other domain still needs _base.
    return $CONFIGURATION{$key} = clone($conf);
}

=head2 domain_config($domain, $conf)

Returns everything that one domain is configured with, as a hash reference: its
own entry with the C<_base> entry merged in.  Recipes read their options from
this.  With no C<$domain>, returns C<_base> alone, which is what a domain gets
when it says nothing itself.

C<$conf> is the configuration to work from, and defaults to C<configuration()>.
A caller that already changed one passes it, for example after it resolved the
C<secret:> references.  Then that work stays, and the caller and this method
cannot merge the same file in different ways.  The return value is a copy, so
the caller can change it freely.

A domain overrides C<_base>.  Where both name the same field, the value of the
domain wins.  Nested objects merge key by key, so a domain that sets one thing
for a recipe keeps everything else that C<_base> says about that recipe.

Lists concatenate and do not replace.  A domain that adds to a list in
C<_base> gets both lists.  Every C<Hash::Merge> behavior does this, so know it
before you put a list in C<_base>.

C<_global> is not in the result.  It says what the guest is, not what a recipe
takes.  See C<global_config>.

=cut

sub domain_config {
    my ( $class, $domain, $conf ) = @_;
    $conf //= $class->configuration();

    my $base = clone( $conf->{_base}                                 // {} );
    my $own  = clone( ( defined $domain ? $conf->{$domain} : undef ) // {} );
    delete $base->{_global};
    delete $own->{_global};

    return _base_merger()->merge( $base, $own );
}

=head2 host_of($domain, $conf)

Returns the domain whose guest holds C<$domain>, if C<$domain> is layered onto
another.  Returns nothing if it has a machine of its own, or if C<$domain> is
undef.  C<_shared> holds that arrangement: each host, and the domains built
onto it.

Recipes ask for this, and nothing passes it from recipe to recipe.  A guest
runs one of each service for all the domains on it.  So a recipe that reads the
configuration of a sibling asks about the machine, not the domain.  Examples
are the credential of the DNS server and the zone it holds.

C<$conf> is the configuration to work from, and defaults to C<configuration()>.
See C<domain_config> for when a caller passes one.

Call it in scalar context.  For a domain with its own machine, this returns an
empty list and not undef.  In a list, the empty list disappears.  So
C<< is( host_of($d), undef ) >> compares the wrong arguments.

=cut

sub host_of {
    my ( $class, $domain, $conf ) = @_;
    return unless defined $domain;

    $conf //= $class->configuration();
    my $shared = $conf->{_shared};
    return unless ref $shared eq 'HASH';

    foreach my $host ( keys %{$shared} ) {
        next unless ref $shared->{$host} eq 'ARRAY';
        return $host if List::Util::any { $_ eq $domain } @{ $shared->{$host} };
    }

    return;
}

=head2 global_config($domain, $conf)

Returns the C<_global> block that a domain is built with, as a new hash
reference.  It is the C<_global> block of C<_base> with the keys of the domain
on top, merged one level deep.  C<$conf> is as in C<domain_config>.

C<_global> holds what several recipes share, not what one recipe owns.  So it
merges apart from the recipes, and C<domain_config> leaves it out.

=cut

sub global_config {
    my ( $class, $domain, $conf ) = @_;
    $conf //= $class->configuration();

    my $base = clone( $conf->{_base}{_global}                                 // {} );
    my $own  = clone( ( defined $domain ? $conf->{$domain}{_global} : undef ) // {} );

    return { %$base, %$own };
}

=head2 record_global($domain, $key, $value)

Writes one C<_global> setting of a domain into its own file,
F<recipes.d/$domain.yaml>, making the file when there is none, and leaving
everything else in it as it was.  Returns the path it wrote.

It is for a setting that a person agreed to rather than typed: the size an
operator accepted for a guest that fitted nowhere else.  See
L<Trog::Hypervisors/select_for($domain, $config)>.

A file of a domain adds to F<recipes.yaml> and does not override it, so a value
in F<recipes.yaml> would win over what this writes.  It refuses rather than
writing something that would not take effect, and says which file to edit.

=cut

sub record_global {
    my ( $class, $domain, $key, $value ) = @_;

    my $main = Trog::Config->path('recipes.yaml');
    my $held = eval { YAML::XS::Load( File::Slurper::read_binary($main) ) } // {};
    die "$main already sets $key for $domain, and a domain's own file does not override it.\n" . "Change it there.\n"
      if defined $held->{$domain}{_global}{$key};

    my $path = Trog::Config->path("recipes.d/$domain.yaml");
    my $conf = eval { YAML::XS::Load( File::Slurper::read_binary($path) ) } // {};

    $conf->{$domain}{_global}{$key} = $value;
    File::Slurper::Temp::write_binary( $path, YAML::XS::Dump($conf) );

    # What is on disk has changed under the copy this process read.
    $class->forget();

    return $path;
}

=head2 global_schema()

The schema of the settings that describe the installation rather than one
recipe: who administers a guest, how it reaches the network, and where its
addresses come from.  They live in the C<_global> of C<_base> in
F<recipes.yaml>, and a domain overrides one in its own C<_global>.

It is a schema and not six lines of perl because a schema validates, defaults,
coerces and documents, and F<bin/recipes> can print it.  These settings were in
F<ipmap.cfg> until they moved here, where every other setting a guest is built
from already lived.  See L<Provisioner::Recipe/args> for the same argument
about a recipe.

C<additionalProperties> stays on in this schema, because C<_global> also
carries settings that a recipe owns, such as C<cpus> for C<vm> and C<distro>
for the distro recipe.  The recipe declares each of those itself.  C<globals>
refuses a key that neither this schema nor a recipe declares.  See
C<declared_globals>.

=cut

sub global_schema {
    return (
        type       => 'object',
        required   => [qw{basedir admin_user admin_gecos admin_email gateway resolvers}],
        properties => {
            basedir     => { type => 'string', description => 'Where the generated configuration of each domain is written on this machine.' },
            admin_user  => { type => 'string', description => 'The account that administers every guest.  Recipes set ownership to it, and the provisioner reaches a guest as it.' },
            admin_gecos => { type => 'string', description => 'The real name of that account, as the guest records it.' },
            admin_email => { type => 'string', description => 'Where mail for the administrator of a guest goes.' },
            gateway     => { type => 'string', format      => 'ipv4', description => 'The default route of a guest on the bridged network.' },

            resolvers => {
                type        => 'array',
                items       => { type => 'string' },
                minItems    => 1,
                description => 'The nameservers a guest asks, in order.  A loopback address belongs to a guest that runs its own, and nostubresolver puts that one in front.',
            },

            linode_type      => { type => 'string', description => 'What this guest is on Linode: a type, such as g6-standard-2.  A guest that names none is not built on Linode.  `linode-cli linodes types` lists them.' },
            openstack_flavor => { type => 'string', description => 'What this guest is on an OpenStack cloud: a flavor, by name or id.  A guest that names none is not built on one.  `openstack flavor list` lists them.' },

            libdir => { type => 'array', items => { type => 'string' }, description => 'Directories outside this checkout.  bin/new_config puts the lib/ of each on @INC and looks for templates in its templates/ after the ones here.' },

            transfer_user => { type => 'string',  description => 'The account on this machine that a guest fetches its payload as.  Unset is the account running the provision.' },
            transfer_port => { type => 'integer', description => 'The ssh port of this machine, when it is not the one this machine reports.' },
            transfer_ip   => { type => 'string',  format      => 'ipv4', description => 'The address of ours that a guest fetches from, for a machine with several routes to the guest.' },

            ip_pool => {
                type        => 'object',
                description => 'The addresses this installation hands out, and the network they are on.  bin/assign_ip takes one from here and records it in ips.db.',
                properties  => {
                    addresses => { type => [qw{array string}], items => { type => 'string' }, description => 'The addresses, as a list or as one string of them.' },
                    cidr      => { type => 'string', description => 'The network the addresses are on, as a prefix.' },
                },
            },

            nameservers => {
                type                 => 'object',
                description          => 'The names of the nameservers that serve the zones of this installation.  bin/ipmap2zones writes them into each zone.',
                additionalProperties => { type => 'string' },
            },

            aliases => {
                type        => 'array',
                items       => { type => 'string' },
                description => 'Other names this domain answers to.  It belongs to the _global of a domain rather than to _base, and a certificate covers each one.',
            },
        },
    );
}

=head2 globals($domain, $conf)

The settings that C<global_schema> declares, for a domain, validated, with the defaults
filled in.  C<$conf> is as in C<domain_config>.

Dies naming every setting that is missing or wrong, and the file to fix, rather
than leaving a recipe to interpolate an undef into a path.  That is one refusal
in one place: before this, F<bin/new_config> hand-wrote six of them and nothing
else checked at all.

A key that C<declared_globals> does not list is wrong too.  Nothing reads it,
and the operator who wrote it believes that something does.

=cut

sub globals {
    my ( $class, $domain, $conf ) = @_;

    my $said = $class->global_config( $domain, $conf );

    # Coerced here rather than in the schema, because one address written as a
    # string is what an operator writes, and every reader wants a list.
    $said->{resolvers} = Provisioner::Utils::coerce_arrayref( $said->{resolvers} )
      if exists $said->{resolvers};

    my %schema    = $class->global_schema;
    my $validator = JSON::Validator::Schema::Troglodyne->new;
    $validator->coerce( { %{ $validator->coerce }, defaults => 1 } );

    my @errors = $validator->validate( $said, \%schema );

    my %declared = map { $_ => 1 } $class->declared_globals;
    push( @errors, map { "/$_: Nothing declares this setting, so nothing reads it." } grep { !$declared{$_} } sort keys %$said );

    die "The settings of this installation are not valid" . ( defined $domain ? " for $domain" : q{} ) . ":\n" . join( "\n", map { "  $_" } @errors ) . "\nThey are the _global of _base in recipes.yaml, and a domain overrides one in its own _global.\n"
      if @errors;

    return $said;
}

=head2 @keys = declared_globals()

Returns, sorted, every key that a C<_global> can hold.  That is each key that
C<global_schema> declares, and each key that the C<schema> of a recipe
declares, the C<directors> included.  A recipe receives only the keys of
C<_global> that its schema names, so a key that is not in this list reaches
nothing.

It loads every recipe, and so dies as C<load> does.

=cut

sub declared_globals {
    my ($class) = @_;

    my %global = $class->global_schema;
    my @keys   = keys %{ $global{properties} };

    foreach my $name ( $class->names, $class->directors ) {
        my %schema = $class->load($name)->schema;
        push( @keys, keys %{ $schema{properties} // {} } );
    }

    my @declared = sort( uniq(@keys) );
    return @declared;
}

=head2 \%aliases = alias_map($conf)

The other names each domain answers to, keyed by domain.  A domain names them
in the C<aliases> of its own C<_global>.

Every domain, not only the one being built: a zone holds the names of the
fleet, and F<templates/files/pdns.zone.tt> writes them.  C<$conf> is as in
C<domain_config>.

=cut

sub alias_map {
    my ( $class, $conf ) = @_;
    $conf //= $class->configuration();

    my %aliases;
    foreach my $domain ( grep { !m/\A_/ } keys %$conf ) {
        my $said = $class->global_config( $domain, $conf )->{aliases} or next;
        $aliases{$domain} = Provisioner::Utils::coerce_arrayref($said);
    }

    return \%aliases;
}

=head2 install_dir($domain, $conf)

Returns the directory on the guest where the files of a domain live.  It comes
from C<_global>, not from the C<data> recipe, so a recipe that uses
C<install_dir> does not depend on C<data>.  Returns F</opt/domains> if the
configuration says nothing.

=cut

sub install_dir {
    my ( $class, $domain, $conf ) = @_;

    my $said = $class->global_config( $domain, $conf )->{install_dir};
    return $said if $said;

    return '/opt/domains';
}

=head2 data_source($domain, $conf)

Returns the directory on the hypervisor that holds what gets shipped to the
guest.  It comes from C<_global>, like C<install_dir>.

This has no default.  A guess for C<install_dir> is harmless, because it is only
a path in a rendered configuration.  But the teardown deletes what is under the
data source.  So if the configuration says nothing, this returns undef, which
means that there is nothing to sweep.

=cut

sub data_source {
    my ( $class, $domain, $conf ) = @_;

    my $said = $class->global_config( $domain, $conf )->{data_source};
    return $said if $said;

    return undef;
}

=head2 data_dir($domain, $conf)

Returns the directory of the domain under the data source.  Returns undef if
C<$domain> is empty or if nothing names the data source.

C<bin/new_config> makes the data directories of the recipes in it, and writes
into it what it fetched from the last guest.  The guest fetches its payload
from this machine, not from the hypervisor.
C<bin/destroy --purge-data> removes it.

=cut

sub data_dir {
    my ( $class, $domain, $conf ) = @_;
    return undef unless $domain;

    my $from = $class->data_source( $domain, $conf );
    return undef unless $from;

    return "$from/$domain";
}

=head2 forget()

Clears what C<configuration> and C<remember> hold, and returns 1.  A test uses it
to write a configuration, read it, and write it again.

=cut

sub forget { %CONFIGURATION = (); return 1 }

=head1 SEE ALSO

L<Provisioner::Recipe>

=cut

1;
