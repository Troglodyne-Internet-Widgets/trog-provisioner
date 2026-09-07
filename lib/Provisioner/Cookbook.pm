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

=head2 names

Every recipe there is, sorted.

=cut

sub names {
    my ($class) = @_;

    my $dir = $class->recipe_dir;
    opendir( my $dh, $dir ) or die "Could not read $dir: $!\n";
    my @names = sort map { m/\A(\w+)\.pm\z/ ? $1 : () } readdir $dh;
    closedir $dh;

    return @names;
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

=head2 load($name)

Load the recipe and hand back its class name.  Dies naming the recipe, and
saying what there is instead, because a typo here is the likeliest reason to
be calling it.

=cut

sub load {
    my ( $class, $name ) = @_;

    die "No recipe named '" . ( $name // '' ) . "'.\n" . "Try `bin/recipes` for the ones there are.\n"
      unless $class->has($name);

    my $module = "Provisioner::Recipe::$name";
    require "Provisioner/Recipe/$name.pm";    ## no critic (Modules::RequireBarewordIncludes)

    die "$module loaded but is not a Provisioner::Recipe\n"
      unless $module->isa('Provisioner::Recipe');

    return $module;
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
not reported as needing anything.  This matters more than it sounds: the merge
is STORAGE_PRECEDENT, so C<_base> wins over a domain's own block, and a
placeholder written over a field C<_base> supplies would be quietly discarded
rather than stopping at validation.

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

        # An object with a shape gets that shape; one that is just a bag of
        # whatever (additionalProperties) has nothing to scaffold, so it is
        # left out rather than guessed at.
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

# Named rather than inherited: bin/new_config sets Hash::Merge's process-wide
# behaviour, so the functional interface means one thing inside that script and
# the default anywhere else.  This is the one the merged configuration has
# always had -- where two of these disagree, the more general one wins.
sub _merger { state $merger = Hash::Merge->new('STORAGE_PRECEDENT'); return $merger }

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

    my $merger = _merger();
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

C<_global> is not part of it.  It says what the guest is rather than what a
recipe takes, and the two halves of it combine the other way round: the
domain's own wins there, where C<_base> wins here.

=cut

sub domain_config {
    my ( $class, $domain, $conf ) = @_;
    $conf //= $class->configuration();

    my $base = clone( $conf->{_base}                                 // {} );
    my $own  = clone( ( defined $domain ? $conf->{$domain} : undef ) // {} );
    delete $base->{_global};
    delete $own->{_global};

    return _merger()->merge( $base, $own );
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

    my $from = ( $class->data_config( $domain, $conf ) // {} )->{from};
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
