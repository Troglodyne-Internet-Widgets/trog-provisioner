package Provisioner::Cookbook;

#ABSTRACT: What recipes there are, what each takes, and what a config for them looks like.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use Clone qw{clone};
use Cwd();
use File::Basename();
use File::Find();
use List::Util qw{any};
use Provisioner::Utils();
use File::Slurper();
use File::Temp();
use Hash::Merge();
use YAML::XS();

use Trog::Config();

=head1 NAME

Provisioner::Cookbook - what recipes there are, what each takes, and what a
configuration for them looks like before anybody has filled it in.

=head1 SYNOPSIS

    use Provisioner::Cookbook();

    my @all = Provisioner::Cookbook->names();
    my %spec = Provisioner::Cookbook->spec('mariadb');

    my ($config, @todo) = Provisioner::Cookbook->scaffold('mariadb');
    # $config: { version => 'CHANGEME', root_pw => 'CHANGEME', ... }
    # @todo:   qw{mariadb.dumpfile mariadb.root_pw mariadb.version}

=head1 DESCRIPTION

Every recipe declares what it takes in C<args()>, an OpenAPIv3 object schema.
That is enough to answer three questions without running anything: which
recipes exist, what each one will accept, and what the smallest configuration
that could possibly work looks like.

F<bin/recipes> answers the first two and F<bin/new_guest> the third; both are
this module with a command line attached.

Not to be confused with L<Provisioner::Recipe>, which is what a recipe is.
This is the shelf they sit on -- and it deliberately does not live under
F<Provisioner/Recipe/>, because everything there is discovered and loaded as a
recipe.

=head1 CLASS METHODS

=head2 recipe_dir

Where the recipe modules are, found relative to this file so that it is the
same answer from a checkout and from an installed dist.

=cut

sub recipe_dir { return File::Basename::dirname(__FILE__) . '/Recipe' }

=head2 template_dir

Where the templates are, found relative to this file for the same reason
C<recipe_dir> is.

=cut

sub template_dir { return Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../../templates' ) }

=head2 template_dirs($distro, @libdirs)

The template search path for a build, in the order a renderer should try it.

A distribution's own directory comes before the generic one, so
F<templates/ubuntu/nginx.tt> wins over F<templates/nginx.tt> by being found
first -- which is the whole mechanism, and needs no code that knows about it.
Every fragment is written against apt and systemd today and so lives under
F<ubuntu/>; F<templates/> holds what is genuinely shared, which is
F<makefile.tt> and most of F<files/> and F<tests/>.

The same for each vendor F<libdir>, after the checkout, since a vendor recipe
adds to what ships here rather than overruling it.

=cut

sub template_dirs {
    my ( $class, $distro, @libdirs ) = @_;

    my @bases = ( $class->template_dir, map { "$_/templates" } @libdirs );
    return [ map { ( ( ( defined $distro && length $distro ) ? "$_/$distro" : () ), $_ ) } @bases ];
}

=head2 names

Every recipe you can ask a domain to be built with, sorted.

Not quite every module under F<Recipe/>: the two that direct a build rather than
taking part in it are left out, since neither is something to write under a
domain.  See C<directors>.

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

Every host any recipe names in C<fetch_hosts>, sorted and once each: what
L<Provisioner::Recipe::fetchcache> fetches from unless it is told otherwise.

Loads every recipe to ask it, which C<names> deliberately does not, and asks
once a process: the answer is a fact about the code.

=cut

sub fetch_hosts {
    my ($class) = @_;

    state @hosts = List::Util::uniq( sort map { $class->load($_)->fetch_hosts } $class->names );
    return @hosts;
}

=head2 configured_fetch_hosts

Every host the domains this installation is configured with will actually
download from: each domain's recipes asked C<fetch_hosts> with that domain's own
configuration, rather than asked of the class with none.

C<fetch_hosts> above cannot answer this.  It is asked of the class, so a recipe
whose upstream is configured -- koan's and trogrunner's C<repo_url>, admincode's
C<api_url> -- can only name the host its default points at.  A guest gets the
configured one, because C<bin/new_config> asks with the configuration in hand;
what needed this is the cache, which builds its certificate and its
C<server_name> from a list that had no configuration behind it and so did not
answer for a host only somebody's F<recipes.d> entry names.

Not memoized here on purpose: C<configuration> already remembers each file it
read, keyed by path, and a second cache with a different lifetime is how the
first one goes stale under a test that points C<TROG_PROVISIONER_CONFIG>
somewhere else.

=cut

sub configured_fetch_hosts {
    my ($class) = @_;

    my $conf = $class->configuration();
    my @hosts;

    # _base is what every domain gets rather than a guest of its own.
    foreach my $domain ( grep { $_ ne '_base' } sort keys %$conf ) {
        my $config = $class->domain_config( $domain, $conf );

        foreach my $recipe ( sort keys %$config ) {

            # A configuration naming a recipe this installation does not have is
            # somebody else's error to report, not a reason to fetch nothing.
            next unless $class->has($recipe);
            eval { push( @hosts, $class->load($recipe)->fetch_hosts( %{ $config->{$recipe} // {} } ) ); 1 } or do {
                die "The $recipe recipe could not say which hosts $domain fetches from: $@";
            };
        }
    }

    return List::Util::uniq( sort grep { defined && length } @hosts );
}

=head2 cache_classes

Every cache class any recipe declares, as C<{ class =E<gt> ..., pattern =E<gt>
... }>: what L<Provisioner::Recipe::fetchcache> keeps for how long.  Asked of
every recipe rather than of the ones a domain uses, for the reason
C<fetch_hosts> is -- the cache serves a fleet and cannot depend on any one
domain.

=cut

sub cache_classes {
    my ($class) = @_;

    state @classes = map { $class->load($_)->cache_classes } $class->names;
    return @classes;
}

=head2 implementations($interface)

The recipes that implement an interface -- the ones whose class C<isa> it --
sorted.  C<Provisioner::DNSRecipe> has two, C<pdns> and C<registrar>.

Loads every recipe to ask, which C<names> deliberately does not, and asks once a
process for each interface: which classes inherit from what is a fact about the
code rather than about a configuration.

This is what lets C<bin/new_config> resolve a substitutable dependency.  A
recipe can say it needs something that can answer a dns-01 challenge without
naming the one that happens to exist.

=cut

sub implementations {
    my ( $class, $interface ) = @_;

    # names() and directors() together: names deliberately leaves out the
    # recipes that direct a build, and those implement interfaces too -- every
    # Provisioner::DistroRecipe there is, is one.  Asked of names alone this
    # answered "nothing implements that" for a real interface.
    state %by_interface;
    $by_interface{$interface} //= [
        sort grep {
            eval { $class->load($_)->isa($interface) }
        } ( $class->names, $class->directors )
    ];

    return @{ $by_interface{$interface} };
}

=head2 directors

The recipes that direct a build instead of running in one: C<vm>, and the
distro recipe for every distribution there is a namespace for.

They are recipes in every way that counts -- they declare C<args>, they are
configured out of F<recipes.yaml>, C<bin/recipes> will print their schema -- but
naming one under a domain would be as odd as naming the hypervisor there, so
C<names> does not offer them.  C<has> and C<load> still answer for them.

Answered by name rather than by asking each module its C<is_module>, because
C<names> deliberately loads nothing: that is the whole reason C<abstract> reads
the file instead.  C<t/recipes.t> holds the two answers against each other.

=cut

sub directors {
    my ($class) = @_;
    return ( 'vm', $class->distros() );
}

=head2 distros

The distributions there are recipes for, lowercased -- the C<distro> a domain's
C<_global> may name.

One per capitalized subdirectory of the recipe directory: C<Recipe/Ubuntu/>
holds Ubuntu's specializations, and C<Recipe/ubuntu.pm> is the distro recipe
itself.  Read off the directory rather than listed, so adding a distribution is
adding files.

=cut

sub distros {
    my ($class) = @_;
    my @distros = sort map { lc } Provisioner::Utils::dirs_in( $class->recipe_dir );
    return @distros;
}

=head2 has($name)

Whether there is a recipe by that name.

=cut

sub has {
    my ( $class, $name ) = @_;
    return 0 unless defined $name && $name =~ m/\A\w+\z/;

    my $path = $class->recipe_dir . "/$name.pm";
    return -f $path;    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether there is one is the whole question; load() opens it for itself
}

=head2 load($name, %opts)

Load the recipe and hand back its class name.  Dies naming the recipe, and
saying what there is instead, because a typo here is the likeliest reason to
be calling it.

C<distro> asks for that distribution's specialization of the recipe --
C<Provisioner::Recipe::Ubuntu::nginx> rather than C<Provisioner::Recipe::nginx>
-- and is how the package names for a build get chosen.  A recipe with no
specialization for that distribution comes back as itself, which is right: most
recipes install nothing, and a shared C<deps> is a shared C<deps>.

B<Absence is the only thing that falls back.>  The subclass is looked for on
disk and then C<require>d outright, so a subclass that does not compile takes
the run down.  Wrapping that in an C<eval> and falling back on failure would
turn a typo in F<Ubuntu/mail.pm> into a guest with no postfix on it and nothing
said about why -- and the same goes for a subclass that forgot its C<parent>,
which is what the second C<isa> catches: it would otherwise inherit the base
class's empty C<deps> and install nothing, quietly.

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

The one-line description off the recipe's C<#ABSTRACT> line, or undef.  Read
out of the file rather than loaded, so listing every recipe costs one readdir
and 42 opens instead of 42 module loads.

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

The recipe's C<args()>, as a hash.

C<args()> is an instance method -- C<validate> calls it as one -- and a recipe
is within its rights to compute a default off C<$self>, so this calls it on an
object rather than on the class name.  C<%opts> become that object's fields;
C<output_dir> defaults to a scratch directory, because at least one recipe
generates a secret and writes it there as a side effect of being asked what it
takes.  Describing a recipe should not leave anything behind in whatever
directory you happened to be standing in.

Worth knowing: a recipe may do real work here.  The garage recipe asks GitHub
for the current release to use as its version default, so C<spec('garage')>
makes a network request and takes as long as that does.

=cut

sub spec {
    my ( $class, $name, %opts ) = @_;

    my $module = $class->load($name);

    state $scratch;
    $opts{output_dir} //= ( $scratch //= File::Temp::tempdir( CLEANUP => 1 ) );

    return bless( \%opts, $module )->args();
}

=head2 properties($spec)

The properties of an object schema.

Only C<properties>, which is what OpenAPIv3 calls it and what the validator
reads.  Seven recipes used to spell it C<parameters>, which the validator
ignores -- so those fields were not being checked at all.  They are fixed, and
t/recipes.t will not let another one in.

Reading both was tempting and would have been wrong: a scaffold that offers
fields the validator does not look at is telling you the recipe accepts
something it will not actually check.  Better to agree with the validator and
have the misspelling show up as an empty schema.

=cut

sub properties {
    my ( $class, $spec ) = @_;
    return {} unless ref $spec eq 'HASH';
    return ref $spec->{properties} eq 'HASH' ? $spec->{properties} : {};
}

=head2 defaults($name, %opts)

What a recipe's schema declares as defaults, as a hash of field to value.

For the callers that have to fill a field in themselves rather than letting the
validator do it -- C<bin/new_config> writing F<provision.conf>, C<bin/new_guest>
writing a domain block -- so that the number they write is the one the recipe
would have used and not a second opinion about it.

Only the top level, and only fields that declare one.  A nested default belongs
to the object it is declared in and is the validator's to apply; see
L<Provisioner::Recipe/args>.

=cut

sub defaults {
    my ( $class, $name, %opts ) = @_;

    my $props = $class->properties( { $class->spec( $name, %opts ) } );
    return map { exists $props->{$_}{default} ? ( $_ => $props->{$_}{default} ) : () } keys %$props;
}

=head2 PLACEHOLDER

What goes in a field the recipe requires and has no default for.  It is a
string on purpose, and an obvious one: a required boolean filled in with a
plausible-looking C<0> would provision quietly and wrongly, where this stops
at validation and says which key it was.

=cut

sub PLACEHOLDER { return 'CHANGEME' }

=head2 scaffold($name, %opts)

The smallest configuration for a recipe that could work, and a list of the
paths in it that still need a human.

    my ($config, @todo) = Provisioner::Cookbook->scaffold('mariadb');

Required fields get their default if the recipe has one and a placeholder if
it does not.  Everything else is left out, so the recipe's own defaults keep
applying rather than being frozen into a file the day it was generated.

C<all> includes the optional fields too, defaults where there are defaults --
the full menu, for when you are going to edit it anyway.

C<provided> is configuration that is already coming from somewhere else -- the
C<_base> block of F<recipes.yaml>, usually.  Those fields are left out and are
not reported as needing anything, because there is nothing to fill in: asking
for a value that is already supplied is how a generated file grows fields
nobody meant to pin.

Returns undef for a recipe that needs nothing, which is how the config files
already spell it: a bare C<nosnap:> with nothing under it.

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

        # Nothing an operator writes: a readOnly field is answered by whatever
        # builds the guest, so offering one to fill in would be asking for a
        # value that gets overwritten.
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

        # An object with declared properties gets scaffolded from them; one that
        # is only additionalProperties has nothing to scaffold, so it is left
        # out rather than guessed at.
        my ( $sub, @todo ) = $class->_scaffold_object( $prop, $path, $opts );
        return ( undef, () ) unless %$sub;
        return ( $sub,  @todo );
    }

    if ( $type eq 'array' ) {
        my ( $item, @todo ) = $class->_scaffold_value( $prop->{items} // {}, "$path\[0]", $opts );
        return ( [],      () ) unless defined $item;
        return ( [$item], @todo );
    }

    return ( $class->PLACEHOLDER, $path );
}

=head2 scaffold_dependencies(\@named, %opts)

The blocks a domain needs for recipes nobody named, and the paths in them that
still want a human.

    my ( $blocks, @todo ) = Provisioner::Cookbook->scaffold_dependencies( ['grafanasyslog'] );

C<scaffold> answers for one recipe, and C<bin/new_guest> asks it about each
recipe on the command line -- which is not the set the guest is built from.
C<bin/new_config> closes that set over C<required_recipes>, so a recipe nobody
named arrives with required fields of its own.  Usually the recipe that asked
for it supplies them.  Where it cannot, somebody has to be told: C<grafana>
wants an C<admin_password>, and a password is not a thing a depending recipe can
choose on an operator's behalf, so without this the report says there is nothing
to fill in and C<bin/new_config> refuses once a guest is already going up.

Only dependencies that still want something come back.  The depsolver adds the
recipe either way, so a block here is somewhere to put a value rather than a
request for the recipe.

Two things it will not guess at.  A key naming an interface rather than a recipe
is resolved by the depsolver against the domain's configuration, which is not
available here.  And C<bin/new_config> hands a C<required_recipes> sub the
requiring recipe's own options, so one called without them may die -- C<tcms>
builds a path out of C<install_dir> and C<domain> -- and a sub that died has
said nothing about what it supplies.  A placeholder standing in front of a field
the recipe that asked for it would have filled is worse than no placeholder at
all, so that dependency is left alone.

=cut

sub scaffold_dependencies {
    my ( $class, $named, %opts ) = @_;

    my $base   = ref $opts{base} eq 'HASH'          ? $opts{base}          : {};
    my $global = ref $opts{global_config} eq 'HASH' ? $opts{global_config} : {};
    my $distro = $global->{distro} // 'ubuntu';

    # What a recipe is built with, worked out here rather than asked of the
    # caller: bin/new_guest has no business knowing which packager a
    # distribution uses, and a caller that guessed would be a second answer to a
    # question this module already has one for.
    # One for the process, the way spec() takes one: a recipe is instantiated
    # with somewhere to write, nothing here writes, and a directory per call
    # would be a directory per call left behind.
    state $scratch;
    my %provisioner = (
        distro          => $distro,
        target_packager => $class->load($distro)->packager,
        template_dirs   => $class->template_dirs($distro),
        output_dir      => $opts{output_dir} // ( $scratch //= File::Temp::tempdir( CLEANUP => 1 ) ),
    );

    # One entry per named recipe, which is what the walk merges each
    # dependency's contributions into.
    my %domain_conf = map { $_ => clone( $base->{$_} // {} ) } @$named;

    my ( $modules, $builders ) = $class->resolve_dependencies(
        modules       => [@$named],
        domain_conf   => \%domain_conf,
        global_config => $global,
        distro        => $distro,
        provisioner   => \%provisioner,
        domain        => $opts{domain},
    );

    # Named by the caller, who has scaffolded them already.
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

Every place in a configuration that is still a placeholder, as dotted paths.

A placeholder is a perfectly good string, so nothing downstream would object to
one: C<root_pw: CHANGEME> validates, provisions, and gives you a database whose
root password is CHANGEME.  Somebody therefore has to look, and this is what
they look with.

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

Which recipe satisfies a substitutable dependency: one naming an interface that
any of several recipes could answer for, rather than naming a recipe outright.

The interface decides -- this asks it, rather than working it out again.  Two
answers to one question is how the gates this replaced came to disagree, so the
rules live in one place and both callers, here and the recipe rendering its own
templates, put the same question to it.

What this adds is the part the interface cannot know: that the answer has to be
a recipe this installation actually has, and one that implements what was asked
for.  A configuration naming something else is a typo, and saying so beats
loading it and finding out three targets later.

C<interface> is the interface that was named, and C<domain> the domain naming it.

C<domain_conf> is what the domain itself is configured with.  C<host_conf> is
what the machine it is layered onto is, and C<host> names that machine so a
refusal can say which guest it looked at -- both of those undef for a domain
with a guest of its own.

C<requiring_conf> is the configuration of the recipe that declared the
dependency: the interface names the key holding a preference and reads it from
there, so a domain settles a tie where it already writes it.

=cut

sub resolve_substitutable_dependency {
    my ( $class, %args ) = @_;
    my ( $interface, $domain_conf, $host_conf, $requiring_conf, $domain, $host ) = @args{qw{interface domain_conf host_conf requiring_conf domain host}};

    # For the same reason resolve_dependencies requires it: all three refusals
    # below open with it, and one that cannot name the domain is not worth much.
    die "resolve_substitutable_dependency needs the domain asking; pass one.\n" unless $domain;

    # It arrives as text out of required_recipes, so nothing has loaded it and
    # every method call below would be "perhaps you forgot to load".
    my $path = $interface =~ s{::}{/}gr;
    eval { require "$path.pm"; 1 } or die "$domain depends on $interface, which will not load: $@";    ## no critic (Modules::RequireBarewordIncludes)

    my @known = $class->implementations($interface);
    die "$domain depends on $interface, which no recipe here implements.\n" unless @known;

    # The configuration this run was pointed at, not the installation's: they
    # are the same thing for a fleet provision and different for every scratch
    # one, and the resolver has no way to tell which it is being asked about.
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

Close a domain's module list over what its recipes require, and configure what
that drags in.

    my ( $modules, $builders ) = Provisioner::Cookbook->resolve_dependencies(
        modules       => [ $distro_name, sort keys %{ $conf->{$domain} } ],
        domain_conf   => $conf->{$domain},
        global_config => \%global,
        distro        => $distro_name,
        provisioner   => \%provisioner_opts,
        domain        => $domain,
    );

A recipe says what it needs in C<required_recipes>, and what it needs may need
something in turn, so the list is walked as it grows rather than iterated once.
Each dependency is added, configured out of whatever the recipes depending on it
asked for, and C<reconcile>d where two of them wanted different things.

What comes back is the expanded list and the builders instantiated along the
way, which reusing is the caller's responsibility rather than loading every
recipe a second time.  C<domain_conf> is written into: a dependency's
configuration ends up the merge of what the domain wrote and what each dependent
handed it.

The list comes back in the order the build wants it.  A dependency is named
again every time something requires it, and the last of those is the one that
counts -- it has to run after everything that dragged it in -- so the list is
C<lastuniq>'d before it is returned.  Which entries are modules at all is
L<Provisioner::Recipe/is_module>, and that is the caller's to filter.

C<domain> is required.  Getting this far without knowing which domain is being
provisioned is not a thing to paper over with a default: a caller with no real
one has a bogus one to supply and a reason to think about why.

=head3 Two sources, on purpose

Dependencies are composed from the base class's C<required_recipes> as well as
the recipe's own, and the base class's is called explicitly rather than through
the recipe.  What the base class decides every recipe owes -- C<ufw> its rate
limits, C<data> its restores -- is not something an override should be able to
drop by forgetting to chain to C<SUPER>, and six of them do exactly that.

=head3 When a recipe cannot say what it wants

A C<required_recipes> sub is handed the global configuration and the requiring
recipe's own, and reaches into both: C<tcms> builds a path out of C<install_dir>
and C<domain>.  Called without them it dies, and what it says on the way out is
about a path rather than about a configuration.  So this names the recipe that
could not answer and what it was asked about.  That configuration comes from C<_global>
in F<recipes.yaml>, and a caller that has not got them has a file to fix rather
than a dependency to skip.

=cut

sub resolve_dependencies {
    my ( $class, %args ) = @_;

    my @modules       = @{ $args{modules} // [] };
    my $domain_conf   = $args{domain_conf}   // {};
    my $global_config = $args{global_config} // {};
    my $distro        = $args{distro};
    my $provisioner   = $args{provisioner} // {};

    # Required.  Every refusal below opens with it, and depsolving without
    # knowing which domain is being provisioned is not a state to carry on from.
    my $domain = $args{domain}
      or die "resolve_dependencies needs the domain being provisioned; pass one, bogus if that is what the caller has.\n";

    my $depmod_conf = {};
    my %builders;

    # Each recipe's configuration as the domain wrote it, taken on its first
    # visit.  A recipe other recipes depend on is visited once for each of
    # them, and what they handed it has to be merged into what the domain
    # wrote each time -- merged into the last visit's result instead, a list
    # they handed it came out once per visit.
    my %as_written;

    # A C-style loop is the only one that recomputes the array's extents every
    # iteration, and so the only way to iterate recursively in perl: what a
    # recipe requires may require something itself, and lands on this list while
    # it is being walked.
    for ( my $i = 0; $i < scalar(@modules); $i++ ) {
        my $module  = $modules[$i];
        my $builder = $builders{$module} //= $class->load( $module, distro => $distro )->new(%$provisioner);

        my $pconf = $domain_conf->{$module} // {};

        # The base's own answer first, then the recipe's.  See L</Two sources, on purpose>.
        my %dep_recipes = (
            Provisioner::Recipe::required_recipes( $builder, %$global_config, %$pconf ),
            $builder->required_recipes( %$global_config, %$pconf ),
        );
        foreach my $required ( keys(%dep_recipes) ) {

            # A dependency may be substitutable -- naming an interface several
            # recipes could answer for -- and this is where it becomes one of
            # them: has() takes \w+ and nothing else, so the name has to be
            # resolved before anything below tries to load it or put it in the
            # module list.
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

            # See about autocomputing the options if possible.
            my %depargs;
            if ( ref $dep_recipes{$required} eq 'CODE' ) {
                my $said;
                my $answered = eval { %depargs = $dep_recipes{$required}->( %$global_config, %$pconf ); 1 };
                $said = $@ unless $answered;
                die "$domain: the $module recipe could not say what it wants from $required.\n" . "It said: $said" . "A required_recipes sub reads the global configuration it is handed, so this is usually one of those missing.  Those come from _global in recipes.yaml.\n"
                  unless $answered;
            }
            my %cur_args = %$manual_args ? ( $required => $manual_args ) : ( $required => \%depargs );

            # Every time something names it.  The duplicates are the point: the
            # last mention is the one lastuniq keeps, which is what puts a
            # dependency after everything that dragged it in.
            push( @modules, $required );
            $depmod_conf = $class->_dep_merger->merge( $depmod_conf, \%cur_args );

            # Hash::Merge picks a side where two dependents disagree.  The recipe
            # being depended on is the only thing that knows whether either side
            # is right, so it gets asked -- and dies if it does not know.
            $class->load( $required, distro => $distro )->reconcile( $depmod_conf->{$required}, $cur_args{$required} );
        }

        # Merge the configuration provided by all things depending on this.
        $as_written{$module} //= clone($pconf);
        if ( $depmod_conf->{$module} ) {
            $domain_conf->{$module} = $class->_dep_merger->merge( $depmod_conf->{$module}, $as_written{$module} );

            # Same on this side of it: what an operator wrote for this recipe is
            # held against what the recipes depending on it asked for.
            $builder->reconcile( $domain_conf->{$module}, $_ ) for ( $depmod_conf->{$module}, $as_written{$module} );
        }
    }

    return ( [ Provisioner::Utils::lastuniq(@modules) ], \%builders );
}

# Two merges, wanting opposite things, so two mergers.
#
# Named rather than inherited: bin/new_config sets Hash::Merge's process-wide
# behavior, so the functional interface means one thing inside that script and
# the default anywhere else.
#
# _base is a base of defaults and a domain overrides it, so that merge takes the
# right.  It took the left until this was fixed, which meant a domain could not
# override anything _base named -- see the account in domain_config.
#
# The file merge keeps the left, and that one is deliberate: a domain's own file
# adds to what recipes.yaml says rather than overruling it.  See configuration().
sub _base_merger { state $merger = Hash::Merge->new('RIGHT_PRECEDENT');   return $merger }
sub _file_merger { state $merger = Hash::Merge->new('STORAGE_PRECEDENT'); return $merger }

# The depsolver's, for the two merges that accumulate what several recipes asked
# of a shared dependency.
#
# The left is kept on purpose: these build up a dependency's options one
# requester at a time, and where two of them genuinely disagree it is reconcile
# that settles it, having been shown both sides.
#
# An object rather than the process-wide behavior.  bin/new_config set that
# globally and called Hash::Merge::merge, which worked only because it was the
# only caller -- and a second set_behavior naming the other precedence once sat
# under that line and silently undid it, which is what inverted _base for
# everything.  Nothing can undo this one from a distance.
sub _dep_merger { state $merger = Hash::Merge->new('STORAGE_PRECEDENT'); return $merger }

=head2 configuration($path)

The recipe configuration an installation is running on: F<recipes.yaml> with
every F<recipes.d/*.yaml> beside it merged into it, keyed by domain.  C<$path>
defaults to the F<recipes.yaml> in L<Trog::Config>'s directory, and an absent
one is an empty configuration rather than an error.

A domain's own file adds to what the main file says rather than overruling it:
a key both of them carry keeps the value F<recipes.yaml> gave it.  C<_base> and
C<_shared> are dropped from the per-domain files outright, since what every
guest gets is not something one guest gets to say.

Read once per file and remembered, on the grounds that nobody edits the
configuration underneath a command that is already running on it.

=cut

# Keyed by resolved path: a run that reads two installations gets two answers,
# and one that reads the same file twice does the work once.
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

Seat C<$conf> as the configuration for C<$path>, so everything that asks for it
afterwards is answered with this one.

There is exactly one caller and one reason.  C<bin/new_config> reads the
configuration, clones it, and resolves every C<secret:> reference into the
clone -- so the copy remembered here still says C<secret:group/entry/field>
where the clone says the password.  A recipe reading a sibling's configuration
through C<domain_config> got the reference, and rendered it into the file that
was supposed to authenticate with it.  Measured: a domain whose registrar
credentials are a secret reference exported
C<LEXICON_EASYDNS_AUTH_TOKEN="secret:g/e/password"> into its dehydrated hook,
while the same run configured the server with the real one.

Keyed the way C<configuration> keys, so the two cannot disagree about which
file they are talking about, and cleared by C<forget> like anything else it
remembers.

=cut

sub remember {
    my ( $class, $path, $conf ) = @_;

    my $key = Cwd::abs_path( $path // Trog::Config->path('recipes.yaml') );

    # A copy, because the caller goes on using theirs.  bin/new_config seats the
    # configuration it resolved and then folds _base into the domain it is
    # building and deletes _base outright -- and holding its reference meant
    # every later reader lost the inheritance.  Not visibly for the domain being
    # built, whose _base was folded in a line earlier, but for every other one:
    # a domain layered onto another asks about its host, and got a host with
    # nothing _base gave it.
    return $CONFIGURATION{$key} = clone($conf);
}

=head2 domain_config($domain, $conf)

Everything one domain is configured with: its own entry with the C<_base> entry
folded into it, which is what a recipe's options are read out of.  With no
domain, C<_base> alone -- what a domain gets when it says nothing itself.

C<$conf> is a configuration to work from, defaulting to C<configuration()>.  A
caller that has already done something to one -- resolved the C<secret:>
references in it, say -- passes it, so that work is not thrown away and the two
of you cannot end up merging the same file differently.  What comes back is a
copy, so fold it, delete out of it, hand it to a recipe.

A domain overrides what C<_base> says: C<_base> is a base of defaults, and a
domain naming the same field gets its own value.  Nested objects merge key by
key, so a domain saying one thing about a recipe keeps everything else C<_base>
said about it.  B<Lists concatenate rather than replace> -- a domain adding to a
list C<_base> names gets both, which is what every C<Hash::Merge> behavior does
and is worth knowing before putting a list in C<_base>.

That is a correction.  Until it was made this merge took C<_base>'s side, so a
domain could not override anything C<_base> named and the value it wrote was
discarded without a word.  Both C<set_behavior> calls arrived together in
C<027e1cf>, which meant to make inheritance deeper and inverted it instead: the
first said the domain wins, and the second, being process-wide, said the
opposite.

C<_global> is not part of it.  It says what the guest is rather than what a
recipe takes, and it has always merged this way round -- see C<global_config>.

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

The domain whose guest holds C<$domain>, where it is layered onto another, and
nothing where it has a machine of its own.  That arrangement is C<_shared>: a
host, and the domains built onto it.

Asked rather than handed down from recipe to recipe.  A guest runs one of each
service between all the domains on it, so a recipe reading what a sibling is
configured with -- the credential the DNS server runs with, the zone it holds --
has to ask about the machine rather than about the domain, and this is what
names it.

C<$conf> is a configuration to work from, defaulting to C<configuration()>; see
C<domain_config> for when a caller passes one.

Ask it in scalar context.  Where a domain has a machine of its own this returns
nothing rather than undef, which in a list vanishes instead of becoming one --
so C<< is( host_of($d), undef ) >> compares the wrong pair of arguments.

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

The C<_global> block a domain is built with: what C<_base> says, with the
domain's own on top.

C<_global> is what several recipes share rather than what any one of them owns,
which is why it is merged separately from the recipes themselves -- see
C<domain_config>, which deliberately leaves it out.

=cut

sub global_config {
    my ( $class, $domain, $conf ) = @_;
    $conf //= $class->configuration();

    my $base = clone( $conf->{_base}{_global}                                 // {} );
    my $own  = clone( ( defined $domain ? $conf->{$domain}{_global} : undef ) // {} );

    return { %$base, %$own };
}

=head2 install_dir($domain, $conf)

Where a domain's files live on the guest.

This is C<_global>'s to say, not the C<data> recipe's.  It used to be read out
of C<data>'s C<to> field, which meant every recipe interpolating C<install_dir>
depended on the data recipe for the path rather than for anything data does --
and that is what kept data from being an ordinary recipe.

Falls back to that field for a configuration written before the move, and to
F</opt/domains> for one that says neither.

=cut

sub install_dir {
    my ( $class, $domain, $conf ) = @_;

    my $said = $class->global_config( $domain, $conf )->{install_dir};
    return $said if defined $said && length $said;

    my $legacy = ( $class->data_config( $domain, $conf ) // {} )->{to};
    return $legacy if defined $legacy && length $legacy;

    return '/opt/domains';
}

=head2 data_source($domain, $conf)

Where the hypervisor keeps what gets shipped to the guest.

The other half of the same move: C<_global>'s to say, falling back to C<data>'s
C<from>.

B<No default.>  Unlike C<install_dir>, which is a path to render into a
configuration and harmless to guess at, this one is what the teardown sweeps --
so a configuration that says nothing has to come back undef and mean "nothing
to sweep", rather than pointing something destructive at a directory nobody
named.

=cut

sub data_source {
    my ( $class, $domain, $conf ) = @_;

    my $said = $class->global_config( $domain, $conf )->{data_source};
    return $said if defined $said && length $said;

    my $legacy = ( $class->data_config( $domain, $conf ) // {} )->{from};
    return $legacy if defined $legacy && length $legacy;

    return undef;
}

=head2 data_config($domain, $conf)

What the C<data> recipe is configured with for a domain: C<from>, the directory
on the machine doing the provisioning, and C<to>, where it lands on the guest.

Undef when the configuration does not say, which is fatal to a provision and
merely nothing to do for anything cleaning up after one.

=cut

sub data_config {
    my ( $class, $domain, $conf ) = @_;
    return $class->domain_config( $domain, $conf )->{data};
}

=head2 data_dir($domain, $conf)

The domain's own directory under the data source.  C<bin/new_config> makes the
recipes' datadirs in it, writes whatever it fetched off the last guest into it,
and ships it to the hypervisor for the guest to pull its payload out of; the
teardown in the provisioning-recipes skill is what takes it away again.

Undef when nothing says where the data source is.

=cut

sub data_dir {
    my ( $class, $domain, $conf ) = @_;
    return undef unless defined $domain && length $domain;

    # Through data_source, so that a domain saying where its data lives in
    # _global gets the same answer as one that still says it under data.
    my $from = $class->data_source( $domain, $conf );
    return undef unless defined $from && length $from;

    return "$from/$domain";
}

=head2 forget()

Drop what C<configuration> remembers.  For a test that writes a configuration,
reads it, and writes it again.

=cut

sub forget { %CONFIGURATION = (); return 1 }

=head1 SEE ALSO

L<Provisioner::Recipe>

=cut

1;
