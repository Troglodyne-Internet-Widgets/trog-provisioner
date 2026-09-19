package Provisioner::Recipe;

#ABSTRACT: Base class for provisioner recipes.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util qw{any};
use Text::Xslate;
use Text::Xslate::Bridge::TT2;
use Clone qw{clone};
use Scalar::Util();
use File::Copy();
use File::Slurper::Temp();

use JSON::Validator::Schema::Troglodyne;
use Mojo::JSON::Pointer();

=head1 NAME

Provisioner::Recipe - Base class for the recipes, with what every recipe can do and what each one must declare.

=head2 SYNOPSIS

    package Provisioner::Recipe::example;
    use parent qw{Provisioner::Recipe};

    sub deps { qw{nginx-full} }
    sub enrich { my ($self, %opts) = @_; return %opts; }
    sub template_files { ('example.conf.tt' => 'example.conf') }
    sub args { ( type => 'object', required => [qw{fooArg}], properties => { fooArg => { type => 'string', default => 'bar' } } ) }

=head2 DESCRIPTION

A framework that builds deployment makefiles out of templated fragments.  It
supports recipes that depend on other recipes, autoconfiguration and more.

A recipe is one installable thing, for example a web server, a mail stack or a
language runtime.  It answers two questions.  Which packages does it need?
What must the guest run to end up with it configured?  C<bin/new_config> turns
the recipes named for a domain into a makefile, and C<bin/provision> builds a
guest and runs it.
L<docs/CONFIGURATION.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/docs/CONFIGURATION.md>
describes what an operator writes to ask for a recipe.

=head3 Naming

The last component of the package name must be lowercase:
C<Provisioner::Recipe::nginx>, never C<::Nginx>.  The makefile has uppercase
targets of its own, and the case keeps a recipe from colliding with one of them.

A recipe can have one specialization per distribution, in a capitalized
namespace named for that distribution.  C<Provisioner::Recipe::Ubuntu::nginx> is
a subclass of C<Provisioner::Recipe::nginx>.  It answers to the same name, and
C<Provisioner::Cookbook/load> finds it from the C<distro> of the domain.  It
shares the fragment of its parent.  A distribution changes C<deps>, and the
makefile it renders stays the same.

=head3 Where the packages are named

C<deps> belongs in the distro subclass, because a package name is a fact about
a distribution and not about the software.  The recipe itself declares no
C<deps> and inherits the empty one below.

This makes one failure quiet.  A recipe that needs packages and has no subclass
for the current distribution installs none of them.  Nothing reports it until a
service does not start.  C<t/recipes.t> catches it: it asserts that every recipe
with packages has them for every distribution.  If you add a distribution and
forget a recipe, that test fails before a guest does.

=head3 The fragment is a makefile, not a shell script

Each recipe renders C<templates/E<lt>distroE<gt>/E<lt>nameE<gt>.tt> into a
fragment of the makefile that runs on the guest.  Write it with no leading tab,
because the tab is added for you.  Everything else follows the rules of make,
not of a shell.  These differences cause failures:

=over 4

=item * Make removes a single C<$> before the shell sees it.  A shell expansion
therefore needs C<< $$ >>.

=item * Every line runs in its own shell.  A variable set on one line is gone on
the next, and a command that spans lines needs a C<\> at the end of each.  A
heredoc cannot work at all.  Render the script through C<template_files> and
install it.

=item * Recipe lines run under C</bin/sh>, which is dash on Ubuntu, not bash.
Dash has no brace expansion.  In dash, C<&E<gt>> starts a background job and
then redirects.  It does not redirect both streams.

=back

Fragments must be re-entrant, because the makefile runs with C<make -j>.  That
is the purpose of C<deps>.  Everything that must happen first is declared up
front and installed in one pass, so no target races to install its own
packages.

=head3 Global and per-domain parts

A guest can host several domains.  Some of what a recipe does is per domain,
and some of it happens once for the machine.  A recipe can have a
C<E<lt>nameE<gt>.global.tt> beside its fragment.  That file runs once, however
many domains the guest holds.  The per-domain fragment runs for each domain.
Configuration for a service with no C<conf.d> directory usually belongs in the
global half, because two domains cannot each rewrite the same file.

L<Provisioner::Recipe::configd> removes that limit for the software it covers.
It gives such a file a fragment directory, and a recipe writes into it per
domain like into any other C<conf.d>.  The global half then keeps only the
facts about the guest, not about a domain.  See how C<mail> splits main.cf:
milters declared per domain make postfix run each of them twice.

=head3 Conventions a recipe must keep

=over 4

=item * Everything the domain owns lives under C<install_dir>, so a backup is
one directory.  Prepend C<install_dir> to every path a fragment names.  If
software insists on a path of its own, symlink that path into C<install_dir>.

=item * Files and directories are C<0750 user:admin_user>.  C<user> is the
service account that the application runs as.  It defaults to the admin user,
see C<validate>.

=item * A task that needs a shell script goes in C<scripts/>, not in the
fragment.  C<scripts/> is copied to the guest whole.

=back

=head3 Order

The C<data> recipe runs first.  The rest run in the order the depsolver
settles.  A recipe comes before everything it requires, because C<lastuniq>
keeps the last mention of a dependency and each recipe that requires it names
it again.

You cannot ask for a position.  If one thing must exist before another, use
C<[% script_dir %]/queue_postrun_task>, or wait for it in your own fragment.
Both work under C<make -j>, and an order does not.

=head3 Where a template is looked for

Fragments live in F<templates/E<lt>distroE<gt>/>, because every fragment is
written against apt and systemd today.  F<templates/> holds F<makefile.tt> and
the files that all distributions share, which is most of F<files/> and
F<tests/>.  The directory of the distribution comes first on the search path.
A file there overrides the generic one, and nothing else has to know.

Two mistakes in a template fail silently.  First, an apostrophe in a
C<[%# ... %]> comment opens a string that runs to the next quote and swallows
the text between them.  A second apostrophe closes it only on the same line,
because a string literal cannot span a newline.  C<t/recipes.t> checks each line
of a comment for this.  Second, the whitespace before C<[%#> is emitted.  A
comment indented to match its block therefore also indents the line after it.
In a YAML document, that changes the meaning.

=head3 Recipes you do not intend to publish

Git ignores a C<vendor/> directory in the checkout.  Point the C<libdir>
parameter in the configuration of a domain at it, and recipes there are found
like any other.  See C<bin/new_config> for the search path.

=cut

=head2 STATIC METHODS

=head3 $name = $recipe->recipe_name()

The name this recipe answers to, called on a class or an object.  It is the
last component of the class name.  A distro specialization such as
C<Provisioner::Recipe::Ubuntu::pdns> therefore answers to the same name and uses
the same fragment as the recipe it specializes.  A distro changes the package
list, not the makefile.

Returns undef for a class whose name is not a recipe name.

=cut

sub recipe_name {
    my ($self) = @_;
    my ($name) = ( Scalar::Util::blessed($self) // $self ) =~ m/\AProvisioner::Recipe::(?:\w+::)?(\w+)\z/;
    return $name;
}

=head3 $recipe = $class->new(%opts)

Creates a recipe instance.  C<template_dirs> in C<%opts> is the list of
directories that the renderer searches for templates.

Dies if the class name is not a recipe name, or if the renderer does not start.

=cut

sub new {
    my ( $class, %opts ) = @_;

    my $tname = $class->recipe_name;
    die "Could not extract recipe name.  Recipes must be of form Provisioner::Recipe::* or Provisioner::Recipe::<Distro>::*" unless $tname;

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

=head2 METHODS you can override

=head3 $bool = $recipe->is_module()

Returns true if this recipe is one of the modules that the makefile of the
guest is built from.

True for every recipe that installs something, which is nearly all of them.
False for the two that direct the build and do not take part in it:
L<Provisioner::DistroRecipe> and L<Provisioner::Recipe::vm>.  All their work
happens before a guest exists to run a makefile.

C<bin/new_config> depsolves those two like any other recipe, so they are
configured and other recipes can depend on them.  Then it leaves them out of the
module list.  This matters beyond the makefile.  Every template and every recipe
gets C<modules> as the list of what is on this guest, and neither of these two
is on it.

They are also the only two that talk to a L<Trog::HV>.  Each one receives it
from its caller and does not create it, see L<Provisioner::Recipe::vm/hv>.
Neither loads L<Trog::HV>, and this class has no accessor for it.  That keeps
L<Sys::Virt> out of an ordinary recipe, so C<bin/recipes> does not need libvirt
installed to print a schema.

=cut

sub is_module { return 1 }

=head3 $bool = $recipe->is_multi_tenant()

Returns true if two domains on one guest can both be configured with this
recipe.

True for nearly everything.  A recipe that writes per-domain files, or whose
service reads a C<conf.d>, does not care how many domains the guest holds.
L<Provisioner::Recipe::configd> makes this true for services that keep their
configuration in one file and have no C<conf.d>.

False for a service that can only belong to one domain.  One synapse has one
C<server_name>.  A second domain does not add itself but silently replaces the
first.  C<bin/new_config> refuses to generate such a recipe for a domain layered
onto another.  It does not let the domain provisioned last win.

This is a different question from what belongs in the global half.  The global
half is work done once for the machine, and a recipe with much of it can still
serve several domains.  This method says whether the domains can coexist at
all.

=cut

sub is_multi_tenant { return 1 }

=head3 %args = $recipe->args()

Declares the arguments of the recipe as a hash for the schema() method of
L<JSON::Validator>.  The schema must be openapiv3.

=cut

sub args {
    my ($self) = @_;
    return ();
}

=head3 %args = $recipe->global_args()

The settings that every recipe receives, declared in one place.

C<bin/new_config> builds one hash per domain from F<ipmap.cfg>, the address
pool, the machine it runs on and the C<_global> of the domain.  It gives that
hash to every recipe it renders.  None of these keys belongs to one recipe, so
no recipe declares them in its C<args()>.  They are declared here, and C<schema>
puts them under what the recipe declares for itself.

Under, because a recipe that declares a key of the same name describes a
different thing, and the recipe knows what it means.  The C<user> of
L<Provisioner::Recipe::registrar> is the account at the registrar, and its
default is empty.  That empty default stops C<validate> from copying
C<admin_user> into it.  Without it, the lexicon shortcut exports an
C<AUTH_USERNAME> for a registrar that authenticates with a token alone.  The
C<admin_user> of L<Provisioner::Recipe::matrix> is the Synapse account.

Nothing here declares a default, and nothing here is required, for three
reasons:

=over 4

=item * A default satisfies a recipe that requires the key.  koan requires
C<user>.  A default of the admin account counts as an answer on every domain
that names no service account.

=item * C<validate> copies C<admin_user> into C<user> after validation, so that
fallback cannot satisfy a required field.  Also, C<forget_undefs> drops an
empty key only where a default is declared.  A default here turns C<user:> with
no value into the same silent fallback.

=item * C<bin/new_config> always writes C<users>, C<resolvers> and the
addressing block over whatever C<_global> said.  A default here can never take
effect, and it documents an intention that never happens.

=back

C<size> is not here.  For L<Provisioner::Recipe::vm>, it is the guest disk in
bytes.  For L<Provisioner::Recipe::tmpfs>, it is a sizing string like C<50%>.
One word has two meanings, and neither is a setting that every recipe receives.
C<vm> already declares its own, and C<bin/recipes vm> prints it.  C<cpus> and
C<memory> stay out for the same reason.  C<distro>, C<mirror> and C<cache> stay
out because L<Provisioner::DistroRecipe/args> declares them.

C<libdir> travels in the same hash and is not declared here either.  It lists
the extra library directories that an operator names in C<_global>, so that
recipes outside this checkout are found.  C<bin/new_config> uses it before any
recipe exists.  It pushes it onto C<@INC> and gives it to
L<Provisioner::Cookbook/template_dirs>.

No recipe receives a setting that it does not declare.  C<takes> gives each
recipe only the keys that its own C<schema> names, so that schema can refuse
everything else.  A setting left out here stays out of the hash.  A setting
that a recipe declares still arrives.

=cut

sub global_args {
    return (
        type       => 'object',
        properties => {
            domain      => { type => 'string', description => 'The fully qualified domain this recipe is being rendered for.' },
            tld         => { type => 'string', description => 'Everything after the first label of that domain.' },
            install_dir => { type => 'string', description => "Where this domain's files live on the guest." },
            data_source => { type => 'string', description => 'Where on this machine the payload shipped to the guest comes from.' },
            script_dir  => { type => 'string', description => 'Where the generated helper scripts land on the guest.' },

            user        => { type => 'string', description => 'The service account the application runs as and recipes set ownership to.  Falls back to admin_user, which is a fallback rather than the intended configuration.' },
            admin_user  => { type => 'string', description => 'The account that administers the guest.' },
            admin_email => { type => 'string', description => 'Where mail for the administrator goes.' },
            admin_keys  => { type => 'array',  items       => { type => 'string' }, description => "The administrator's ssh keys, read from admin_authorized_keys beside the rest of the configuration and written straight into the guest." },

            # These three are absent together.  A hypervisor that addresses its
            # own guests gives out no address of ours, has no NAT bridge to
            # reach, and leaves the guest no gateway of ours.  bin/new_config
            # guards all three on manages_addresses, and
            # Provisioner::Recipe::ubuntu wants a gateway only where there are
            # ips to go with it.
            gateway => { type => 'string', nullable => 1, description => 'The IPv4 gateway guests are built with, or nothing where the platform provides one.' },
            main_ip => { type => 'string', nullable => 1, description => "The guest's static address, or nothing where the hypervisor allocates it." },
            tld_ip  => { type => 'string', nullable => 1, description => "The hypervisor's NAT bridge address, or nothing where it has none." },

            transfer_ip   => { type => 'string',  description => 'The address of this machine the guest rsyncs its payload from.' },
            transfer_ips  => { type => 'array',   items       => { type => 'string' }, description => 'Every address of ours that reaches the guest, the fetch address first.' },
            transfer_user => { type => 'string',  description => 'The account on this machine the guest fetches as.' },
            transfer_port => { type => 'integer', description => 'The ssh port on this machine.' },

            cache_ip => { type => 'string', description => 'The fetch cache, as an address, or empty for none.' },

            resolvers    => { type => 'array', items => { type => 'string' }, description => 'The nameservers this installation is configured with.' },
            full_aliases => { type => 'array', items => { type => 'string' }, description => "This domain's aliases, built from the ip map." },
            modules      => { type => 'array', items => { type => 'string' }, description => 'The recipes on this guest, in the order the makefile runs them.' },

            ipmap       => { type => 'object', additionalProperties => { type => 'string' },                               description => 'Every domain this installation assigns an address to, and its address.' },
            nameservers => { type => 'object', additionalProperties => { type => 'string' },                               description => 'The public nameservers for the zones this fleet serves.' },
            aliases     => { type => 'object', additionalProperties => { type => 'array', items => { type => 'string' } }, description => 'Every domain in the map, and the names that also answer for it.' },

            users => {
                type        => 'array',
                description => "The accounts cloud-init creates on the guest: the administrator, plus whatever the domain's users.yaml adds.",
                items       => {
                    type       => 'object',
                    properties => {
                        name          => { type => 'string' },
                        gecos         => { type => 'string' },
                        shell         => { type => 'string' },
                        sudo          => { type => 'string' },
                        ssh_import_id => { type => 'array', items => { type => 'string' } },
                    },
                },
            },

            packager_invocation        => { type => 'string', description => 'What installs a package on this distribution.' },
            packager_up_invocation     => { type => 'string', description => 'What upgrades one.' },
            packager_remove_invocation => { type => 'string', description => 'What removes one.' },
        },
    );
}

=head3 %schema = $recipe->schema()

Returns what C<validate> checks against.  That is the C<args()> of this recipe,
with C<global_args> under its C<properties>.  The schema refuses every key that
neither of them declares.

Only the properties merge.  Every other key in a schema, such as C<required> or
C<oneOf>, belongs to the recipe alone.  Many recipes declare a C<required> list,
and L<Hash::Merge> concatenates arrays under every behavior it has.  A merge of
C<required> gives koan a list with two C<user> entries.

This method sets C<additionalProperties>, and a recipe does not choose it.  It
makes a key that nothing declares an error, not a value that nobody reads.  A
recipe must therefore receive only what it declares, and C<takes> does that.
C<bin/new_config> keeps the settings that a recipe does not declare out of the
hash it validates, so recipes do not have to declare them all.

The global settings are not folded into C<args()>, on purpose.
L<Provisioner::Cookbook/spec> calls C<args()>.  C<bin/recipes>,
C<bin/new_guest --scaffold>, L<Provisioner::Cookbook/defaults>,
L<Provisioner::DistroRecipe/global_defaults> and the C<hv_settings> of
C<bin/new_config> all read what it returns.  A global declared there appears as
a field of every recipe to scaffold.  Two of those callers read it directly and
not through L<Provisioner::Cookbook/properties>, so hiding global settings at
display time does not work either.

=cut

sub schema {
    my ($self) = @_;

    my %args   = $self->args();
    my %global = $self->global_args();

    return ( %args, additionalProperties => 0, properties => { %{ $global{properties} // {} }, %{ $args{properties} // {} } } );
}

=head3 %mine = $recipe->takes(%offered)

Returns the pairs of C<%offered> that the C<schema> of this recipe declares, and
nothing else.

C<bin/new_config> calls it, because it gives every recipe one hash of settings
per domain.  Some of what travels in that hash does not concern any recipe.
C<libdir> goes onto C<@INC> before any recipe exists, and C<size> belongs to the
hypervisor.  C<schema> refuses what it does not declare, so passing one of those
on causes a refusal.

This filter keeps C<global_args> honest.  It lists what a recipe acts on, not
everything that travels beside it.

The configuration of a recipe does not pass through here.  An unknown key there
is a mistake by the operator, and the schema must refuse it.

=cut

sub takes {
    my ( $self, %offered ) = @_;

    my %schema = $self->schema();
    my $props  = $schema{properties} // {};

    return map { exists $offered{$_} ? ( $_ => $offered{$_} ) : () } keys %$props;
}

=head3 @fmts = $recipe->formatters()

Declares custom template formatters, for use in makefile fragments and in
generated files.

=cut

sub formatters {
    return ();
}

=head3 @pkgs = $recipe->deps(%recipe_config)

The system packages that this recipe needs installed.

Override this in the distro subclass, not in the recipe.  See L</Where the
packages are named>.  A recipe whose packages are the same on every
distribution answers here instead.  C<adminconfig> is one, because the operator
supplies its list.

Empty by default, which is correct for a recipe that installs nothing.

=cut

sub deps {
    return ();
}

=head3 @pkgs = $recipe->dep_conflicts(%recipe_config)

Packages that conflict with this recipe.  They come from another recipe, or
the distribution installs them by default, such as sendmail against postfix.

Every package returned here is removed from the dependency list.

=cut

sub dep_conflicts {
    return ();
}

=head3 @hosts = $recipe->fetch_hosts(%recipe_config)

The hosts that this recipe downloads from on the guest, by name, such as
C<www.cpan.org> or C<codeload.github.com>.

C<bin/new_config> passes the configuration of the recipe for one domain.  The
method must also answer with no configuration, because
L<Provisioner::Cookbook/fetch_hosts> asks the class.  That answer is what
L<Provisioner::Recipe::fetchcache> fetches from by default.

Every recipe that downloads anything must declare this.  A recipe that fetches
a tarball, clones a checkout or pulls a key and names no host here gets none of
the cache.  It is slower than its neighbors, and it fails when the upstream
fails.  C<t/recipes.t> checks the hosts that it can see.

The test cannot see a host that a program reaches on its own.
C<nvm install node> downloads from C<nodejs.org>, and no template names it.  So
the test catches an omission that is written down, and the recipe must still
account for the others.

Leave out the Ubuntu archive.  A guest reaches it through the mirrorlist of
L<Provisioner::Recipe::aptmirror>, which is a mirror and not a cache.  Include a
third-party apt repository, because nothing else fetches from it.
C<apt_repo_classes> is how a recipe adds one.

For a host that the configuration names, such as a C<repo_url> or an
C<api_url>, return that host when C<%recipe_config> gives it.  Return the
default host when it does not.

Empty by default.  On a guest with a C<cache>, each host that its recipes name
points at the cache while the guest provisions.  The cache serves what it kept,
and it serves what it kept last time when the upstream fails.  Name a host only
for downloads that anybody can fetch, because the cache fetches without
credentials.  If downloads from a host redirect to another host, name that host
too.  The cache follows a redirect only to a host that it fetches from.
C<github_release_hosts> gives the hosts for GitHub.

=cut

sub fetch_hosts {
    return ();
}

=head3 @hosts = $recipe->github_release_hosts()

Returns C<github.com> and the hosts that it redirects a release download to.  A
recipe that downloads a GitHub release names these in C<fetch_hosts>.

=cut

sub github_release_hosts {
    return qw{github.com objects.githubusercontent.com release-assets.githubusercontent.com};
}

=head3 @classes = $recipe->cache_classes()

How long L<Provisioner::Recipe::fetchcache> can keep what this recipe
downloads, as a list of C<{ class =E<gt> ..., pattern =E<gt> ... }>.  C<class>
is C<index> for a URL that says which version is current.  It is C<immutable>
for a URL that a version or a commit names, and C<aptindex> for the indexes of
an apt repository, see C<apt_repo_classes>.  A URL that no entry describes gets
the C<default> class of the cache.  C<pattern> is a regex matched against
C<HOST/PATH>.

Empty by default, which gives the default freshness.

This method sits beside C<fetch_hosts> for the same reason.  Which URLs under a
host never change is a fact about that upstream, and the recipe that downloads
from it knows that fact.  If the cache held the list itself, every new upstream
in a recipe means an edit to the cache.

=cut

sub cache_classes {
    return ();
}

=head3 @classes = $recipe->github_release_classes()

The C<cache_classes> entries for a recipe that downloads a GitHub release.  A
release asset and a source archive named by tag or commit never change.
C<releases/latest> is the link that says which release is current.

These live here, not in each recipe, for the same reason as
C<github_release_hosts>.  The layout belongs to one upstream.  Without this,
gogs, roundcube and matrix each carry a copy, and the copies drift apart when
GitHub changes it.

=cut

sub github_release_classes {
    return (
        { class => 'index',     pattern => '[^/]+/[^/]+/[^/]+/releases/latest(?:/|$)' },
        { class => 'immutable', pattern => '[^/]+/[^/]+/[^/]+/releases/download/' },
        { class => 'immutable', pattern => '[^/]+/[^/]+/[^/]+/archive/(?:[0-9a-f]{40}|refs/tags/)' },
    );
}

=head3 @classes = $recipe->apt_repo_classes($host)

The C<cache_classes> entries for a third-party apt repository on C<$host>.  The
indexes are under F<dists/>.  The packages are under F<pool/>, and because a
version names each one, they never change.

These live here, not in each recipe, because several recipes add an apt source
and the layout belongs to apt.  The indexes get their own class because the
cache must never serve them stale.  C<InRelease> lists the hashes of the
C<Packages> beside it.  A stale copy of one with a fresh copy of the other
causes a hash sum mismatch.  No repository that this fleet uses publishes
C<Acquire-By-Hash>, which makes the indexes content-addressed and removes the
problem.  So the C<aptindex> class turns C<proxy_cache_use_stale> off.

=cut

sub apt_repo_classes {
    my ( $self, $host ) = @_;

    my $h = quotemeta $host;
    return (
        { class => 'aptindex',  pattern => "$h/(?:[^/]+/)*dists/(?!.*/by-hash/)" },
        { class => 'immutable', pattern => "$h/(?:[^/]+/)*(?:pool|by-hash)/" },
    );
}

=head3 %required = $recipe->required_recipes(%opts)

The recipes that this recipe depends on, as pairs of a recipe name and a sub.
C<bin/new_config> builds each one as a synthetic recipe and adds it to the list
of things to provision.

Example output:

    my %out = (
        nginxproxy => sub { # returns hash, expects same %opts as validate() },
    );

This lets you configure a dependency inside the recipe that depends on it, not
separately.

Example usage in a recipe conf:

    tcms:
        nginxproxy: ...
        ...

The sub returns options for the dependency.  It fills in mandatory options that
the configuration leaves out.  In some cases, you can then leave the dependency
out of the configuration entirely.

The base class requires C<ufw> when C<rate_limits> or C<listens> names a port,
C<fail2ban> when C<jails> returns jails, and C<data> when C<restores> returns
something.  An override does not need to call
C<SUPER::required_recipes> for those, because C<bin/new_config> asks the base
class itself.  See L<Provisioner::Cookbook/Two sources, on purpose>.

=head3 Substitutable dependencies

A key that names an interface, not a recipe, is a substitutable dependency.
Such a key contains C<::>.  C<bin/new_config> resolves it to the recipe that
implements that interface and serves this domain:

    my %out = (
        'Provisioner::DNSRecipe' => sub { return () },
    );

This is how L<Provisioner::Recipe::letsencrypt> asks for something that can
answer a C<dns-01> challenge.  It does not name C<pdns>, which is one of the two
recipes that can.  The interface decides which one.  The depsolver asks it, and
it names the configuration key that settles a tie.  So the depsolver knows
nothing about the capability itself.  See
L<Provisioner::DNSRecipe/implementation_for>.

The answer must be a recipe that this installation has and that implements the
interface.  A configuration that names anything else is refused there, before
any target runs.

=cut

sub required_recipes {
    my ( $self, %opts ) = @_;

    my @required;

    # A recipe that names limits listens, and something must apply them.
    # Declaring the dependency here means that ufw does not have to know every
    # recipe that listens.  Each port it binds is claimed under its name, and
    # ufw's schema allows one name to a port.  A bare port and /tcp are one port.
    my %limits    = $self->rate_limits(%opts);
    my $name      = $self->recipe_name();
    my %listeners = map { s{/tcp\z}{}r => { $name => 1 } } keys(%limits), $self->listens(%opts);
    push( @required, ufw => sub { return ( rate_limits => \%limits, listeners => \%listeners ) } ) if %listeners;

    # Likewise for the jails of fail2ban.
    my %jails = $self->jails(%opts);
    push( @required, fail2ban => sub { return ( jails => \%jails ) } ) if %jails;

    # Likewise for state: a recipe that says where its salvage goes back
    # depends on data, which walks what every dependent gave it.
    # Provisioner::Cookbook always passes the domain, which letsencrypt and pdns
    # interpolate into the paths they restore.
    my %restores = $self->restores(%opts);
    push( @required, data => sub { return ( restores => \%restores ) } ) if %restores;

    return @required;
}

=head3 $merged = $recipe->reconcile($merged, $incoming)

Settles what two dependents disagree about.  Returns C<$merged>, changed in
place.

Several recipes can depend on one recipe.  It is configured once, from what each
of them asked for.  If two of them ask for different values in the same field,
the merge silently picks one, by an order that nobody chose.  This method walks
the two structures and gives each such collision to C<resolve_conflict>.  It
writes back what that method decides.

It looks only at fields that hold plain scalars in both structures.  It follows
nested hashes and leaves arrays to the merge.  Call it with the merged result
and the contribution that just arrived.  One call per contribution gives the
same answer as a look at all of them at once.

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

        # The merge already kept one of the two, so a field that only one of
        # them named needs nothing done to it.
        next if !defined $theirs || !defined $mine;
        next if ref $theirs      || ref $mine;
        next if $theirs eq $mine;

        $merged->{$field} = $self->resolve_conflict( [ @$path, $field ], $mine, $theirs );
    }

    return $merged;
}

=head3 $value = $recipe->resolve_conflict($path, $mine, $theirs)

Returns the value to use when two dependents ask this recipe for different
values.

C<$path> is the field they disagree about, as an arrayref of keys from the top
of the configuration of the recipe.

Dies by default, and names the field and both values.  This class cannot know
which configuration somebody meant.  If it silently takes one, the guest gets a
configuration that nobody wrote.  Override it only where the recipe does know.
C<Provisioner::Recipe::ufw> is the example: two recipes that listen on one port
both get the higher of their limits.  An override must say why it is safe.

=cut

sub resolve_conflict {
    my ( $self, $path, $mine, $theirs ) = @_;

    # The distro namespace comes off too.  This names the key that an operator
    # must set, and the configuration only ever says 'ufw', never 'Ubuntu::ufw'.
    my $recipe = Scalar::Util::blessed($self) || $self;
    $recipe =~ s/\AProvisioner::Recipe::(?:\w+::)?//;
    my $field = join( '.', @$path );

    die <<"CONFLICT";
Two recipes want different things from $recipe: $field is '$mine' to one of them and '$theirs' to another.
Nothing here can tell which you meant, so set $field explicitly under $recipe for this domain.
CONFLICT
}

=head3 %limits = $recipe->rate_limits(%opts)

The ports that this recipe listens on.  For each port, the number of new
connections per second from one source that it accepts before it drops more.

A key is a port, optionally followed by a slash and a protocol, such as
C<1194/udp>.  That is how a ufw application profile writes it.  A bare port
means tcp.  A service that uses both protocols names both, because each rule
covers one protocol.  A bare port alone leaves the C<udp> half of such a
service unlimited while it looks limited.

Empty by default.  Most recipes listen on nothing, or reach the network through
something that does.  C<nginx> covers an application behind C<nginxproxy>, not
the application itself.  A recipe that overrides this gets C<ufw> in its
C<required_recipes>.  Its limits merge into the configuration of C<ufw>, which
turns them into firewall rules.

The numbers are a threshold for abuse, not a capacity plan.  Set them well above
what a busy legitimate source does, because a lower limit throttles real users.
This method runs before validation, so read C<%opts> with the same defaults
that the schema declares.

If two recipes name a limit for the same port, the higher one applies.  See
C<resolve_conflict> in L<Provisioner::Recipe::ufw>.  The port and the protocol
together are the key.  C<53> and C<53/udp> are two limits, and neither merges
into the other.

=cut

sub rate_limits {
    return ();
}

=head3 @ports = $recipe->listens(%opts)

The ports that the services of this recipe bind and that C<rate_limits> does
not name, such as a port on loopback that nothing outside the guest reaches.
A port is written as in C<rate_limits>: C<3000> for TCP, C<1194/udp> for UDP.
A range is each of its ports.

Empty by default.  The ports that this returns and the keys of C<rate_limits>
are together the claims of the recipe.  C<required_recipes> hands them to
C<ufw> as C<listeners>, each port with the name of the recipe, and ufw refuses
a configuration in which two recipes claim one port.  A claim with no rate
limit therefore still reaches ufw, and pulls it in.

A service that another recipe runs is that recipe's to claim.  An application
behind C<nginxproxy> binds nothing of its own on 80 or 443, which C<nginx>
claims.  This method runs before validation, so read C<%opts> with the same
defaults that the schema declares.

=cut

sub listens {
    return ();
}

=head3 %jails = $recipe->jails(%opts)

The fail2ban jails that the services of this recipe need, keyed by the name of
the jail.  Each value is a hash of jail options, which the C<fail2ban> recipe
writes into a jail file as C<key = value> lines, under C<enabled = true>.

Empty by default.  A recipe that overrides this gets C<fail2ban> in its
C<required_recipes>, and its jails merge into the configuration of
C<fail2ban>, as C<rate_limits> merge into C<ufw>.  Every jail bans through
ufw, so a ban and a rate limit are in one firewall.

A jail that fail2ban ships, such as C<postfix> or C<nginx-http-auth>, needs no
options: its name enables it, with the filter and the log that fail2ban gives
it.  A jail of our own names a C<logpath> and a C<failregex>, and C<filter> set
to the empty string, so that fail2ban looks for no filter file.

Three things about the options:

=over 4

=item * fail2ban reads C<%> as interpolation, so a literal one is C<%%>.

=item * On Ubuntu, a jail reads the journal unless it says otherwise.  A jail
that reads a log file needs C<backend> set to C<auto>.

=item * The journal that such a jail reads is the system journal.  C<journald>
files what a process with a user ID of 1000 or more writes into the journal of that
user, so a jail for a service that runs as the service user needs C<backend>
set to C<systemd[journalflags=1]>, which reads every journal.

=back

A jail name is shared by every domain on the guest.  Name a jail of your own
after the domain, so that two domains with the same recipe do not collide.

=cut

sub jails {
    return ();
}

=head3 forget_undefs($opts, $schema)

Deletes each field of C<$opts> that is present but undef, where C<$schema>
declares a default for it, so that the default applies.  It also walks
nested hashes.  Returns C<$opts>, changed in place.

The validator fills in a default only when a key is absent.  That is the right
rule for JSON and the wrong one for YAML.  A recipe configuration says

    ntp:
        makestep:

and means "use the default", not "empty".  But it arrives as an explicit undef,
which counts as present.  chronyd does not start with a C<makestep> that has no
arguments, so the difference matters.

A field that declares no default stays undef.  There, a recipe can care about
the difference between unset and absent.

=cut

sub forget_undefs {
    my ( $opts, $schema ) = @_;
    return $opts unless ref $opts eq 'HASH' && ref $schema eq 'HASH';

    my $props = $schema->{properties};
    return $opts unless ref $props eq 'HASH';

    foreach my $key ( keys %$props ) {
        my $prop = $props->{$key};
        next unless ref $prop eq 'HASH';

        delete $opts->{$key}
          if exists $opts->{$key} && !defined $opts->{$key} && exists $prop->{default};

        forget_undefs( $opts->{$key}, $prop ) if ref $opts->{$key} eq 'HASH';
    }

    return $opts;
}

=head3 %opts = $recipe->enrich(%opts)

Sets more options, based on the options already given.  C<validate> calls it
after the schema passes, and returns what it returns.  Put here what a schema
cannot express.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    return %opts;
}

=head3 @paths = $recipe->fetch_sources(%opts)

Directories on I<this machine> that the guest rsyncs from.  C<bin/preflight>
calls this to make sure that they exist before a run starts.

A recipe that ships files of the operator, such as the C<skel> of
C<adminconfig> or the C<cert_dir> of C<openvpnclient>, names a path that nothing
here creates or validates.  The fragment rsyncs it.  If the path is absent, the
target of that recipe fails twenty minutes into a build.  The rsync error does
not say which recipe asked, or for which domain.

This method gets the raw options of the recipe, not the validated ones, before
the build starts.  The configuration can be incomplete.  Return nothing for an
absent field, and do not assume that it exists.

Do not confuse these with C<datadirs>, which this tool creates for the recipe.
Somebody else makes these directories, and the tool only reads them.

=cut

sub fetch_sources {
    return ();
}

=head3 @patterns = $recipe->remote_skip()

rsync exclude patterns for paths under C<remote_files> that must not come down.

C<remote_files> salvages directories, not files.  A directory full of state
worth keeping can still hold something that must stay behind.  The example is a
key that makes a stolen database useless.  On the next guest, that key outlives
the machine it was made for.  In a backup beside the database it protects, it
protects nothing.

A matching file stays where it is.  The old guest keeps it, and the rebuilt
guest makes a new one.  That is the intent, and whatever generated the file
must cope with it.

Two rules decide what a pattern means.  A pattern with no slash matches that
basename at any depth.  A pattern with a slash is anchored at the top of the
transfer, not at the root of the filesystem.  Also, the list applies to every
path in the C<remote_files> of the recipe, and a pattern is relative to the
transfer that runs.  So C<secrets.key> keeps that name out of both salvages of
tCMS, not only out of the configuration directory.

To leave a file behind by mistake is the safe error here.  That is why the last
rule needs no workaround.

=cut

sub remote_skip {
    return ();
}

=head3 %files = $recipe->guest_secrets($install_dir, $domain, %opts)

Files that the guest must have but that must not travel in the payload.
Returns a map from the path on the guest to how the file gets there:

    "/etc/matrix-synapse/homeserver.signing.key" => {
        ref      => "secret:matrix/$domain-signing-key/password",
        generate => \&_signing_key,
        owner    => 'matrix-synapse:matrix-synapse',
        mode     => '0600',
    }

The value lives in the secret store.  C<generate> makes it once, and every
later provision reads it from the store.  C<bin/new_config> writes the
references beside the domain, never the values.  C<bin/provision> resolves them
and puts each file on the guest before the makefile runs.

That is why this is not C<remote_files>.  A secret salvaged off a guest lands
in the domain directory.  From there, it goes into the payload of every rebuild
and into every backup of the domain.  These secrets never do.  Name the file in
C<remote_skip> as well, and the guest is the only place it exists.

A recipe that uses this must not generate the file itself when it is missing.
The file is missing because the store was not reachable.  A new file is a new
identity, and the store exists to prevent that.

C<ref> must name a field that the store keeps: C<password> or C<username>.  The
store keeps a multi-line value and returns it exactly.  So a private key is a
password as far as the store is concerned.

C<%opts> is the configuration of the recipe, for a secret that only some
domains want.  If the recipe returns nothing for a domain, no secret is placed
or generated for it.  Most recipes have an unconditional secret and can ignore
C<%opts>.

C<owner> is the final owner of the file, not the owner it lands with.
Placement happens before the makefile runs, so the account usually belongs to
a package that is not installed yet.  C<mode> keeps the secret private until
the recipe changes the owner, which the recipe must do.

=cut

sub guest_secrets {
    return ();
}

=head3 @dirs = $recipe->datadirs()

Directories under the C<install_dir> of the domain that this recipe needs.

They are made before the fragment runs, with the same ownership as everything
else the domain owns.  A fragment therefore does not need to start with a run
of C<mkdir -p>.

=cut

sub datadirs {
    return ();
}

=head3 @names = $recipe->subdomains()

The names under the domain that this recipe serves, as labels rather than whole
names: C<www>, not C<www.$domain>.

C<bin/new_config> adds one alias per label, asked of every recipe the depsolver
settled on -- so a name belonging to a dependency is added too.  C<full_aliases>
is where the zone, the vhost and the certificate all read it from.

Empty by default, which is the ordinary answer: a recipe reached at the domain
itself declares nothing.

=cut

sub subdomains {
    return ();
}

=head3 @commands = $recipe->remote_prepare($install_dir, $domain)

Shell commands for the guest to run as root immediately before its
C<remote_files> are fetched.

A salvage is only as fresh as whatever wrote it.  A nightly database dump, an
hourly LDIF export, or a snapshot of something that cannot be copied while
open, is old by the time somebody rebuilds the guest.  This closes that gap.
The recipe asks for a new copy now, C<bin/new_config> runs the command, and the
fetch carries the current state of the guest.

    sub remote_prepare { return ('/usr/local/sbin/mariadb-backup.sh') }

A command that fails gives a warning, not an error.  The guest can lack the
script, because its first provision has not run yet.  Last night's dump is
better than no dump, and a die leaves no dump.  The warning must still appear,
because somebody later restores from a salvage that nobody refreshed.  See
C<refresh_salvage> in C<bin/new_config> for when a failure dies.

=cut

sub remote_prepare {
    return ();
}

=head3 %restores = $recipe->restores(%opts)

Where the state that this recipe salvaged must go back.  Returns a map from the
destination on the guest to how to get it there:

    "/var/lib/deluged/config/state" => {
        from  => "$install_dir/$domain/deluged/state",
        owner => 'debian-deluged:debian-deluged',   # optional
        mode  => '0750',                            # optional
    }

The method gets the whole configuration, not a path and a domain.  The owner of
a destination is often another setting, such as C<admin_user> or the service
C<user>, and the recipe then has it in hand.

C<data> walks this map, so the fragment does not call C<restore_state> itself.
The map is keyed on the destination, because the destination must be unique.
Two recipes that restore different things to one path disagree, and
C<reconcile> settles that openly.

This map is not derived from C<remote_files>.  It looks like the inverse, and
it often is, but not always.  C<mail> salvages C</mail/keys> whole and puts one
subdirectory of it back at C</etc/opendkim/keys/$domain>.  No rule that
reverses the map produces that.  A restore to the wrong place destroys data, so
each recipe states its map.

Leave it empty, the default, for a recipe whose salvage lands in the domain
directory that the service already reads.  The C<data> target already puts the
salvage there.

A recipe cannot use this if a service owns the destination and runs before the
makefile starts.  Then the restore must happen between a stop and a start in
the target of that recipe.  C<redis> and C<plexmediaserver> are the two, and
they keep their own C<restore_state> calls.

=cut

sub restores {
    my ( $self, %opts ) = @_;
    return ();
}

=head3 %path_map = $recipe->remote_files($install_dir, $domain)

What to salvage off a guest that already runs this recipe.  Returns a map from
the path on the guest to where it lands in the data directory.

This is how a recipe survives a rebuild of the guest.  State that the guest
generated, not configured, comes back down into the data directory.  Examples
are a database dump, keys that somebody accepted, or a spool.  It goes back up
when the guest is built again.  Do not list anything that the recipe can
regenerate.

If you run C<bin/new_config> from cron and archive what it collects, you have a
backup strategy.  See
L<docs/BACKUPS.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/docs/BACKUPS.md>.

That is also why C<remote_skip> exists.  A directory salvaged whole ends up in
that archive, and some of its contents must stay on the machine that made them.

=head4 Naming a path is not enough

What C<remote_files> names comes down and goes back up.  It lands under
C<install_dir/domain> with everything else in the data directory.  If the
service reads it from another place, the fragment must put it there:

    [% script_dir %]/restore_state '[% install_dir %]/[% domain %]/pdns' /var/spool/powerdns pdns:pdns

C<restore_state> does nothing in three cases:

=over 4

=item * Nothing was salvaged.

=item * The salvage is empty, which is what a fetch leaves when it cannot read
the directory.

=item * The destination already holds state.  This keeps a re-provision of a
live guest from writing a partial copy over the real state.

=back

Call it before the service starts.

A recipe whose state already lives under C<install_dir/domain> needs none of
this.  The data target puts the state back where it came from.  So keep state
there when the software allows it.

=cut

sub remote_files {
    my ( $self, $install_dir, $domain ) = @_;
    return ();
}

=head3 @files = $recipe->template_files(@loaded_recipes)

Files that this recipe generates.  Returns a map from the template under
C<templates/files/> to where it is installed, relative to the configuration
directory of the domain.

A name that does not end in C<.tt> is copied, not rendered.  Use that for a
file with no variables in it.  The method gets the loaded recipes, so a recipe
that generates something per service can generate only what this guest needs.
The application profiles of ufw are an example.

The fragment must install every file named here.  A file that nothing installs
is dead.  Either it must be installed and is not, or it must be removed.
Rendering it only leaves a file on the hypervisor that nothing reads.

=cut

sub template_files {
    my ( $self, @recipes ) = @_;
    return ();
}

=head3 %vars = $recipe->makefile_vars()

Variables set at the top of the generated makefile.  They apply to the whole
run, not only to the fragment of this recipe.

Override this when a fragment needs a value that make itself expands.  Do not
use it to pass configuration to your own templates.  Use C<args> and the
template variables for that.

=cut

sub makefile_vars {
    return ();
}

=head3 @tests = $recipe->tests()

Templates under C<templates/tests/> to render and run on the guest after
provisioning finishes.

With these tests, the recipe reports whether it worked.  They run on the guest,
because only the guest has the answer.  Is the service listening?  Did it load
the configuration it was given?  Does it serve what it must serve?  Assert what
the recipe promises, not what it wrote.  A test that only checks that a file
exists passes on a guest where nothing started.

See L<t/TESTING.md|https://github.com/Troglodyne-Internet-Widgets/trog-provisioner/blob/master/t/TESTING.md>.

=cut

sub tests {
    return ();
}

=head3 @pms = $recipe->testdeps(@modules)

Perl modules that the tests of this recipe need.

=cut

sub testdeps {
    my ( $self, @modules ) = @_;
    return ();
}

=head2 METHODS you usually do not override

=head3 $output = $recipe->render(%template_vars)

Renders the makefile fragment of the recipe.  See C<render_file>.

=cut

sub render ( $self, %template_vars ) {
    return $self->render_file( $self->{template}, %template_vars );
}

=head3 $bool = $recipe->has_global_template()

Returns true if a C<$recipe.global.tt> exists in any configured template
directory.

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

Renders the global makefile fragment of the recipe (C<$recipe.global.tt>).  Call
this only after C<has_global_template> returns true.

=cut

sub render_global ( $self, %template_vars ) {
    return $self->render_file( $self->{global_template}, %template_vars );
}

=head3 $output = $recipe->render_file($file, %template_vars)

Renders the template C<$file> with the C<vars> of the recipe and
C<%template_vars>, after C<validated> checks them.  Dies if they are not valid.

=cut

sub render_file ( $self, $file, %template_vars ) {
    return $self->render_raw( $file, $self->validated( $self->vars(), %template_vars ) );
}

=head3 $output = $recipe->render_raw($file, %template_vars)

Renders a template with variables that already went through C<validate>.

Call C<render_file> instead.  This method is for the one caller that cannot:
C<enrich>, which runs inside C<validate>.  From there, C<render_file> re-enters
C<validate>, which calls C<enrich>, which asks for another render.

A recipe needs this when one of its generated files appears inside another.
The cloud-init of a distro carries the setup script by value, in a
C<write_files> entry.  So the script must be rendered before the user-data that
quotes it.  The answer is a template variable, not an order between two
C<template_files> entries, because C<template_files> promises no order.

=cut

sub render_raw {
    my ( $self, $file, %vars ) = @_;
    return $self->{tt}->render( $file, \%vars );
}

=head3 @written = $recipe->generate_files($output_dir, %template_vars)

Renders everything in C<template_files> into C<$output_dir>.  Returns the paths
it wrote, relative to C<$output_dir>.  Dies if it cannot copy a static file.

A name that ends in C<.tt> is rendered, and any other file is copied, as
C<template_files> says.  This method lives here because it has two callers.
C<bin/new_config> generates the files of a recipe while it walks the modules.
C<bin/provision> generates the files that cannot exist until a hypervisor
answers for itself.  See C<Provisioner::Recipe::vm>.

=cut

sub generate_files {
    my ( $self, $output_dir, %vars ) = @_;

    my %files = $self->template_files( @{ $vars{modules} // [] } );
    my @written;

    foreach my $template ( sort keys %files ) {
        my $destination = "$output_dir/$files{$template}";

        if ( $template =~ m/[.]tt$/ ) {
            File::Slurper::Temp::write_binary( $destination, $self->render_file( "files/$template", %vars ) );
        }
        else {
            my $source = $self->template_path("files/$template");
            File::Copy::copy( $source, $destination ) or die "Could not copy static file $source to $destination: $!\n";
        }

        push( @written, $files{$template} );
    }

    return @written;
}

=head3 $path = $recipe->template_path($file)

Returns the path of a template in C<template_dirs>.  Dies with the list of
directories it searched if none of them has the file.

The renderer finds a template by name on its own.  This method is for a file
that is copied, not rendered, such as a file with no variables in it that
C<template_files> names.  It is also for a caller that must give the path to
something else.

=cut

sub template_path {
    my ( $self, $file ) = @_;

    foreach my $dir ( @{ $self->{template_dirs} } ) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        return "$dir/$file" if -f "$dir/$file";
    }

    die "Could not find the template $file in " . join( ', ', @{ $self->{template_dirs} } ) . "\n";
}

=head3 %opts = $recipe->validate(%opts)

Validates the configuration of the recipe, and returns it as C<enrich> returns
it.  Dies with every schema error, and names the recipe and the domain.

This method is universal, and a recipe must not override it.  It uses
C<schema>, which combines the own C<args> of the recipe with C<global_args>.  It
runs the schema over the options, and then calls C<enrich>.  A subclass that
replaces this method loses all three, its own C<enrich> too.  Put whatever a
schema cannot express in C<enrich>, which runs afterwards.

C<user> defaults to C<admin_user> here, so a recipe needs no C<enrich> to get
one.  That default is a fallback, not the intended configuration.  The service
user owns the files of the domain and runs the application.  Most recipes
expect a user that is not the admin.  So set it, on a test guest as on a
production host.

=cut

sub validate {
    my ( $self, %opts ) = @_;
    my %args = $self->schema();

    # deep copy, so nothing here writes through to the caller's data
    %opts = %{ clone( \%opts ) };

    forget_undefs( \%opts, \%args );

    # Coerce defaults, so that the defaults in the schema apply
    my $validator = JSON::Validator::Schema::Troglodyne->new;
    $validator->coerce( { %{ $validator->coerce }, defaults => 1 } );
    my @errors = $validator->validate( \%opts, \%args );
    if (@errors) {
        my $name  = $self->recipe_name() // ( Scalar::Util::blessed($self) // $self );
        my $where = $opts{domain} ? " for $opts{domain}" : q{};

        die "The $name recipe's configuration$where is not valid:\n" . join( "\n", map { '  ' . _explain( $_, \%opts ) } @errors ) . "\nSee `bin/recipes $name` for what it takes.\n";
    }

    $opts{user} //= $opts{admin_user};

    return $self->enrich(%opts);
}

=head3 $text = _explain($error, $opts)

The text of a schema error.  An error that counts the properties of an object,
such as C<Too many properties: 2/1>, names none of them, so the keys of that
object follow it.  Only the keys: a value can be a password.

=cut

sub _explain {
    my ( $error, $opts ) = @_;

    my ( undef, $keyword ) = @{ $error->details };
    return "$error" unless ( $keyword // '' ) =~ m/\A(?:max|min)Properties\z/;

    my $at = Mojo::JSON::Pointer->new($opts)->get( $error->path );
    return "$error" unless ref $at eq 'HASH';
    return "$error (" . join( ', ', sort keys %$at ) . ')';
}

=head3 %vars = $recipe->validated(%opts)

C<validate>, memoized for the life of the recipe object.

A recipe renders its fragment, then every file in C<template_files>, then each
test.  Each render asks for this, and all of them get the first answer.  So
C<enrich> runs once per recipe object.

One recipe object is one recipe for one domain, and the options are what that
domain merged for it.  C<bin/new_config> builds a recipe once per domain and
renders it once.  C<lastuniq> keeps a module from appearing twice in the list
of a domain.  A dependency that several recipes pull in collects their options
and renders once at the end.  So the first answer is the only answer.

If you call this on one object with different options, you get the answer for
the first set.  That is a bug in the caller, and this method does not handle
it.  If a test needs two configurations, it needs two objects, as
C<new_config> builds them.

The memo is on the object, not in a C<state> variable, because the object has
the right lifetime.  A C<state> variable in a named sub is one variable for the
sub, not one per object, so it outlives the object.  A new recipe with a
configuration that must fail then gets the last valid answer, and never dies.

=cut

sub validated {
    my ( $self, %opts ) = @_;
    $self->{_validated} //= { $self->validate(%opts) };
    return %{ $self->{_validated} };
}

=head3 %vars = $recipe->vars()

Default template variables for the recipe.  C<render_file> gives them to
C<validated> before the variables of the caller.

=cut

sub vars {
    return ();
}

1;
