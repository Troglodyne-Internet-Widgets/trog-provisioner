package Provisioner::Cookbook;

#ABSTRACT: What recipes there are, what each takes, and what a config for them looks like.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use Clone qw{clone};
use Cwd();
use File::Basename();
use File::Find();
use List::Util();
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
    return [ map { ( ( defined $distro && length $distro ) ? "$_/$distro" : () ), $_ } @bases ];
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

One per capitalised subdirectory of the recipe directory: C<Recipe/Ubuntu/>
holds Ubuntu's specialisations, and C<Recipe/ubuntu.pm> is the distro recipe
itself.  Read off the directory rather than listed, so adding a distribution is
adding files.

=cut

sub distros {
    my ($class) = @_;
    return sort map { lc } Provisioner::Utils::dirs_in( $class->recipe_dir );
}

=head2 has($name)

Whether there is a recipe by that name.

=cut

sub has {
    my ( $class, $name ) = @_;
    return 0 unless defined $name && $name =~ m/\A\w+\z/;

    open( my $fh, '<', $class->recipe_dir . "/$name.pm" ) or return 0;
    close $fh;
    return 1;
}

=head2 load($name, %opts)

Load the recipe and hand back its class name.  Dies naming the recipe, and
saying what there is instead, because a typo here is the likeliest reason to
be calling it.

C<distro> asks for that distribution's specialisation of the recipe --
C<Provisioner::Recipe::Ubuntu::nginx> rather than C<Provisioner::Recipe::nginx>
-- and is how the package names for a build get chosen.  A recipe with no
specialisation for that distribution comes back as itself, which is right: most
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

    open( my $fh, '<', $class->recipe_dir . "/$name.pm" ) or return undef;
    while ( my $line = <$fh> ) {
        next unless $line =~ m/\A\s*#\s*ABSTRACT:\s*(.+?)\s*\z/;
        close $fh;
        return $1;
    }
    close $fh;
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

# Two merges, wanting opposite things, so two mergers.
#
# Named rather than inherited: bin/new_config sets Hash::Merge's process-wide
# behaviour, so the functional interface means one thing inside that script and
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
list C<_base> names gets both, which is what every C<Hash::Merge> behaviour does
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
