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
use URI();
use Scalar::Util();
use File::Copy();
use File::Slurper::Temp();

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

A recipe may have one specialisation per distribution, under a capitalised
namespace named for it: C<Provisioner::Recipe::Ubuntu::nginx>, a subclass of
C<Provisioner::Recipe::nginx>.  It answers to the same name, is looked up by
C<Provisioner::Cookbook/load> out of the C<distro> a domain is configured with,
and shares the parent's fragment -- what a distribution changes is C<deps>, and
the makefile it renders is the same one.

=head3 Where the packages are named

C<deps> belongs in the distro subclass, because a package name is a fact about
a distribution rather than about the software.  The recipe itself does not
declare one at all; it inherits the empty C<deps> below.

Which means the failure to know about is a quiet one: a recipe that needs
packages and has no subclass for the distribution in hand installs none of them,
and nothing says so until a service will not start.  C<t/recipes.t> is what
notices -- it asserts that every recipe with packages has them for every
distribution there is, so forgetting one while adding a distribution fails there
rather than on a guest.

Do not reintroduce a C<target_packager> check to get around it; C<t/recipes.t>
refuses one.

=head3 The fragment is a makefile, not a shell script

Each recipe renders C<templates/E<lt>distroE<gt>/E<lt>nameE<gt>.tt> into a
fragment of the makefile that runs on the guest.  Write it with no leading tab; that is added
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
C<E<lt>nameE<gt>.global.tt> beside its fragment gets that one run once no matter
how many domains are provisioned into the guest; the per-domain fragment runs for
each.  Configuration for a service with no C<conf.d> directory tends to belong
in the global half, since two domains cannot each rewrite the same file.

L<Provisioner::Recipe::configd> is how that stops being true for the software it
covers: it gives such a file a fragment directory, and a recipe writes into it
per domain like any other C<conf.d>.  What stays in the global half there is
what is a fact about the guest rather than about a domain -- see the way
C<mail> splits main.cf, where saying the milters per domain would have postfix
run each of them twice.

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

=head3 Where a template is looked for

Fragments live in F<templates/E<lt>distroE<gt>/>, since every one of them is
written against apt and systemd today; F<templates/> holds F<makefile.tt> and
what is genuinely shared, which is most of F<files/> and F<tests/>.  The
distribution's directory comes first on the search path, so putting a file there
overrides the generic one and nothing has to know why.

Two things about writing one that fail silently.  An apostrophe in a
C<[%# ... %]> comment opens a string that runs to the next quote, swallowing
whatever is between; a second apostrophe closes it only when it is on the same
line, since a string literal cannot span a newline -- C<t/recipes.t> checks each
line of a comment for that.  And whitespace before
the C<[%#> is emitted, so indenting a comment to match the block it documents
indents the line after it too, which in a YAML document means something else.

=head3 Recipes you do not intend to publish

A C<vendor/> directory in the checkout is gitignored; point the C<libdir>
parameter of a domain's configuration at it and recipes there are found like any
other.  See C<bin/new_config> for the search path.

=cut

=head2 STATIC METHODS

=head3 $name = $recipe->recipe_name()

The name this recipe answers to, of a class or an object: the last component of
the class, so that a distro's specialisation of a recipe --
C<Provisioner::Recipe::Ubuntu::pdns> -- answers to the same name and looks for
the same fragment as the recipe it specialises.  Sharing the fragment is the
point: what a distro changes is the package list, not the makefile.

Undef for a class not named as a recipe.

=cut

sub recipe_name {
    my ($self) = @_;
    my ($name) = ( Scalar::Util::blessed($self) // $self ) =~ m/\AProvisioner::Recipe::(?:\w+::)?(\w+)\z/;
    return $name;
}

=head3 $class->new(%opts)

Create new recipe instance.

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

=head2 METHODS (you will possibly want to override)

=head3 $bool = $recipe->is_module()

Whether this recipe is one of the modules the guest's makefile is built out of.

True for every recipe that installs something, which is nearly all of them.
False for the two that direct the build instead of taking part in it --
L<Provisioner::DistroRecipe> and L<Provisioner::Recipe::vm> -- whose whole job
happens before there is a guest to run a makefile on.

C<bin/new_config> depsolves those two like anything else, so they are configured
and can be depended upon, and then leaves them out of the module list.  Which
matters for more than the makefile: C<modules> is handed to every template and
every recipe as the list of what is on this guest, and neither of these is.

They are also the only two that talk to a L<Trog::HV>, and each reaches it
itself rather than through an accessor here.  That is deliberate: loading
L<Trog::HV> loads L<Sys::Virt>, and C<bin/recipes> would then need libvirt
installed to print a schema.

=cut

sub is_module { return 1 }

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

The system packages this recipe needs installed.

B<Override this in the distro subclass>, not here -- see L</Where the packages
are named>.  A recipe whose packages are the same everywhere because they are
not packages at all, C<adminconfig>'s operator-supplied list being the one,
answers here instead.

Empty by default, which is the right answer for a recipe that installs nothing.
A recipe that does need packages and has no subclass for the distro in hand is
a recipe that will silently install none of them, which is what C<t/recipes.t>
is there to notice.

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

=head3 @hosts = $recipe->fetch_hosts()

The hosts this recipe downloads from on the guest, by name: C<www.cpan.org>,
C<codeload.github.com>.  Asked of the class rather than of a configured recipe,
because the answer is also what the fetch cache fetches from by default -- see
L<Provisioner::Recipe::fetchcache> -- which cannot depend on any one domain.

B<Every recipe that downloads anything declares this.>  A recipe that fetches a
tarball, clones a checkout, or pulls a key and says nothing here is a recipe
whose downloads never reach the cache -- so it is slower than its neighbours,
and it is the one that fails when upstream does.  Nothing enforced that for a
long time and nine hosts went undeclared; C<t/recipes.t> now checks what it can
see.

What it cannot see is a host a program reaches on its own: C<nvm install node>
downloads from C<nodejs.org> without any template naming it.  So the test
catches an omission that is written down, and the recipe still has to think
about the ones that are not.

The B<Ubuntu archive> stays out: a guest reaches it through
L<Provisioner::Recipe::aptmirror>'s mirrorlist, which is a mirror rather than a
cache.  A B<third-party apt repository> does not -- nothing else fetches those,
and C<apt_repo_classes> is how a recipe adds one.  What also stays out is B<a
host that only a configuration names>: this is asked of the class, with no configuration in hand, so a
C<repo_url> or an C<api_url> pointed somewhere unusual is not declared and goes
straight upstream.

Empty by default.  On a guest with a C<cache>, each host its recipes name is
pointed at the cache while it provisions, so what is downloaded from one is
served out of what the cache has kept, and out of what it kept last time when
upstream is failing.  Name a host only for what can be fetched as anybody: what
the cache keeps, it fetches without credentials.  A host whose downloads
redirect to another names that one too, since the cache follows a redirect only
to a host it fetches from -- C<github_release_hosts> is GitHub's.

=cut

sub fetch_hosts {
    return ();
}

=head3 $host = $recipe->host_of($url)

The host a URL names, or nothing if it names none.

Here because C<fetch_hosts> is handed a configuration and several recipes have
to answer the same question of it: which host is this C<repo_url> or C<api_url>
actually going to reach.  An scp-style git address -- C<git@github.com:o/r.git>
-- is not a URL and L<URI> reads no host out of it, so it is matched separately
rather than silently returning nothing for a form somebody will certainly use:
it is what gogs hands out.

=cut

sub host_of {
    my ( $self, $url ) = @_;

    return unless defined $url && length $url;
    return $1 if $url =~ m{\A[^/\s]+\@([a-z\d][a-z\d.-]*):}i;

    my $host = eval { URI->new($url)->host };
    return $host ? lc $host : ();
}

=head3 @hosts = $recipe->github_release_hosts()

C<github.com>, and the hosts it redirects a release download to: what a recipe
downloading a GitHub release names in C<fetch_hosts>.

=cut

sub github_release_hosts {
    return qw{github.com objects.githubusercontent.com release-assets.githubusercontent.com};
}

=head3 @classes = $recipe->cache_classes()

How long L<Provisioner::Recipe::fetchcache> may keep what this recipe
downloads, as a list of C<{ class =E<gt> ..., pattern =E<gt> ... }>.  C<class>
is C<index> for a URL saying which version is current, and C<immutable> for one
a version or a commit names; anything a recipe does not describe gets the
cache's C<default>.  C<pattern> is a regex matched against C<HOST/PATH>.

Empty by default, which means the default freshness.

This is beside C<fetch_hosts> for the same reason: which URLs under a host never
change is a fact about that upstream, and the recipe that downloads from it is
what knows.  A cache that held the list itself would have to be edited every
time a recipe gained an upstream, which is the coupling this avoids.

=cut

sub cache_classes {
    return ();
}

=head3 @classes = $recipe->github_release_classes()

The C<cache_classes> entries for a recipe that downloads a GitHub release: the
release asset and a source archive named by tag or commit never change, and
C<releases/latest> is the link that says which release is current.

Here rather than in each recipe for the reason C<github_release_hosts> is: it is
one upstream's layout, and gogs, roundcube and matrix would otherwise carry
three copies of it that drift apart when GitHub changes it.

=cut

=head3 @classes = $recipe->apt_repo_classes($host)

The C<cache_classes> entries for a third-party apt repository on C<$host>: the
indexes under F<dists/>, and the packages under F<pool/> which a version names
and which therefore never change.

Here rather than in each recipe because four of them add an apt source and the
layout is apt's, not theirs.  Indexes go in their own class because they are the
one thing the cache must not serve stale: C<InRelease> lists the hashes of the
C<Packages> beside it, and a stale one of the pair against a fresh other is a
hash-sum mismatch.  None of the repositories this fleet uses publishes
C<Acquire-By-Hash>, which would have made the indexes content-addressed and the
question moot, so C<aptindex> turns C<proxy_cache_use_stale> off.

=cut

sub apt_repo_classes {
    my ( $self, $host ) = @_;

    my $h = quotemeta $host;
    return (
        { class => 'aptindex',  pattern => "$h/(?:[^/]+/)*dists/(?!.*/by-hash/)" },
        { class => 'immutable', pattern => "$h/(?:[^/]+/)*(?:pool|by-hash)/" },
    );
}

sub github_release_classes {
    return (
        { class => 'index',     pattern => '[^/]+/[^/]+/[^/]+/releases/latest(?:/|$)' },
        { class => 'immutable', pattern => '[^/]+/[^/]+/[^/]+/releases/download/' },
        { class => 'immutable', pattern => '[^/]+/[^/]+/[^/]+/archive/(?:[0-9a-f]{40}|refs/tags/)' },
    );
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
    my ( $self, %opts ) = @_;

    my @required;

    # A recipe that names limits is a recipe that listens, and something has to
    # apply them.  Saying so here is what makes the dependency explicit rather
    # than ufw knowing the name of every recipe that might be installed.
    my %limits = $self->rate_limits(%opts);
    push( @required, ufw => sub { return ( rate_limits => \%limits ) } ) if %limits;

    # Likewise for state: a recipe that says where its salvage goes back is a
    # recipe that depends on the thing which puts it there.  data walks what
    # every dependant handed it, rather than each fragment calling restore_state
    # for itself.
    my %restores = $self->restores(%opts);
    push( @required, data => sub { return ( restores => \%restores ) } ) if %restores;

    return @required;
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
        next if ref $theirs      || ref $mine;
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

    # The distro's namespace comes off too.  This names the key an operator has
    # to go and set, and there is no 'Ubuntu::ufw' to set anything under -- the
    # configuration only ever says 'ufw'.
    my $recipe = Scalar::Util::blessed($self) || $self;
    $recipe =~ s/\AProvisioner::Recipe::(?:\w+::)?//;
    my $field = join( '.', @$path );

    die <<"CONFLICT";
Two recipes want different things from $recipe: $field is '$mine' to one of them and '$theirs' to another.
Nothing here can tell which you meant, so set $field explicitly under $recipe for this domain.
CONFLICT
}

=head3 %limits = $recipe->rate_limits(%opts)

The ports this recipe listens on, and the new connections a second from a single
source each should take before further ones are dropped.

A key is a port, optionally with a protocol after a slash -- C<1194/udp>, the
way a ufw application profile spells it.  A bare port means tcp.  A service
reached over both names both, because the rule is written per protocol and one
naming neither half is a port that looks limited and is not.

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
C<resolve_conflict> in L<Provisioner::Recipe::ufw>.  Port and protocol together
are the key, so C<53> and C<53/udp> are two limits and neither merges into the
other.

=cut

sub rate_limits {
    return ();
}

=head3 %opts = $recipe->validate(%opts)

Validate recipe configuration.  Enriches opts if the enrich() sub is setup for your recipe.

C<user> defaults to C<admin_user> here, so a recipe needs no C<enrich> of its own
to get one.  That default is a fallback rather than the intended configuration:
the service user owns the domain's files and is what the application runs as,
and most recipes are written for one that is not the admin -- so set it, on a
guest built to test a recipe as on a production host.

=cut

sub validate {
    my ( $self, %opts ) = @_;
    my %args = $self->args();

    # On a copy, all the way down.  %opts is a shallow copy, so everything
    # nested in it belongs to the caller -- and both the coercion below and any
    # enrich write through to it.  The validator turning a vhost's `ssl => 1`
    # into a JSON::PP::Boolean was enough to make the same configuration look
    # like a different one on the next render.
    %opts = %{ clone( \%opts ) };

    forget_undefs( \%opts, \%args );

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
    $validator->coerce( { %{ $validator->coerce }, defaults => 1 } );
    my @errors = $validator->validate( \%opts, \%args );
    die "Had errors validating your recipe:\n" . join( "\n", map { "$classname$_" } @errors ) if @errors;

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

Additionally setup args based on other args passed.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    return %opts;
}

=head3 @paths = $recipe->fetch_sources(%opts)

Directories on I<this machine> that the guest will rsync out of, so that
something can check they are there before a run starts.

A recipe that ships an operator's own files -- C<adminconfig>'s C<skel>,
C<openvpnclient>'s C<cert_dir> -- names a path that nothing here creates and
nothing here validates.  The fragment rsyncs it, so an absent one fails that
recipe's target twenty minutes into a build, and the error rsync gives for it
says nothing about which recipe asked or which domain it was for.

Called with the recipe's raw options rather than its validated ones, and before
a build rather than during one, so it has to cope with a configuration that is
not finished: return nothing for a field that is absent instead of assuming it
is there.  C<bin/preflight> is the caller.

Not to be confused with C<datadirs>, which are directories under the data
directory that this tool makes for the recipe.  These are the ones somebody
else made and we only read.

=cut

sub fetch_sources {
    return ();
}

=head3 @patterns = $recipe->remote_skip()

rsync exclude patterns for paths under C<remote_files> which must not come down.

C<remote_files> salvages directories, not files, so a directory that is mostly
state worth keeping can still hold something that is not.  A key which exists so
that a stolen database is useless is the example: carried onto the next guest it
would be a key that outlives the machine it was made for, and sitting in a backup
beside the database it protects it would be no key at all.

Anything matching is left where it is.  The guest keeps it, and the rebuilt guest
makes a new one -- which is the point, and is what whatever generated it is
expected to cope with.

Two things about the vocabulary, both of which decide what a pattern means.  A
pattern with no slash in it matches that basename at any depth, and one with a
slash is anchored at the top of the transfer rather than at the root of the
filesystem.  And the list is handed to every path in the recipe's
C<remote_files>, not to one of them -- a pattern is relative to whichever
transfer is running, so C<secrets.key> keeps that name out of all four of
tCMS's salvages and not only out of the configuration directory.

Erring towards leaving a file behind is the right way to err here, which is why
that last one is not worth working around.

=cut

sub remote_skip {
    return ();
}

=head3 %files = $recipe->guest_secrets($install_dir, $domain)

Files the guest has to have that must not travel in the payload, as a map of the
path on the guest to how one gets there:

    "$install_dir/matrix.$domain/homeserver.signing.key" => {
        ref      => "secret:matrix/$domain-signing-key/password",
        generate => \&_signing_key,
        owner    => 'matrix-synapse:matrix-synapse',
        mode     => '0600',
    }

The value lives in the secret store: made once by C<generate>, answered from
there every provision after.  C<bin/new_config> writes the references, never the
values, beside the domain; C<bin/provision> resolves them and puts each file on
the guest before the makefile runs.

Which is why this is not C<remote_files>.  A secret salvaged off a guest lands
in the domain directory, and from there into the payload of every rebuild and
into every backup taken of it.  These never do -- name the file in
C<remote_skip> as well and the guest is the only place it sits.

A recipe using this must not generate the file itself when it is missing.  It is
missing because the store could not be reached, and a fresh one is a new
identity, which is the thing the store exists to prevent.

C<ref> must name a field the store keeps, which is C<password> or C<username>.

C<owner> is what the file ends up owned by, not what it lands as.  Placement
happens before the makefile, so the account usually belongs to a package that is
not installed yet; C<mode> is what keeps the secret to itself until the recipe
chowns it, which the recipe has to do.

=cut

sub guest_secrets {
    return ();
}

=head3 @dirs = $recipe->datadirs()

Directories under the domain's C<install_dir> this recipe needs to exist.

Made before the fragment runs, owned the way everything else the domain owns is
owned, so a fragment does not have to open with a run of C<mkdir -p>.

=cut

sub datadirs {
    return ();
}

=head3 @commands = $recipe->remote_prepare($install_dir, $domain)

What the guest should be asked to do immediately before its C<remote_files> are
fetched, as shell commands run there as root.

A salvage is only as fresh as whatever wrote it.  A database dumped nightly, an
LDIF exported hourly, a snapshot of something that cannot be copied while it is
open -- all of them are a cron away from the moment somebody actually rebuilds
the guest, and the difference is however much happened in between.  This is
where a recipe closes that gap: it says "take one now", and C<bin/new_config>
asks, and the fetch that follows carries what the guest looks like at that
moment rather than what it looked like last night.

    sub remote_prepare { return ('/usr/local/sbin/mariadb-backup.sh') }

A command that fails is a warning rather than an error.  The guest may not have
the script yet -- it is being asked before its first provision has run -- and
last night's dump is worth more than no dump at all, which is what dying here
would leave.  What it must not be is silent, since a salvage nobody refreshed is
one somebody will restore from later believing otherwise.

=cut

sub remote_prepare {
    return ();
}

=head3 %restores = $recipe->restores(%opts)

Where the state this recipe salvaged has to be put back, as a map of the
destination on the guest to how to get it there:

    "/var/lib/deluged/config/state" => {
        from  => "$install_dir/$domain/deluged/state",
        owner => 'debian-deluged:debian-deluged',   # optional
        mode  => '0750',                            # optional
    }

Handed the whole configuration rather than a path and a domain, because what a
destination is owned by is often one of the other settings -- C<admin_user>,
the service C<user> -- and a recipe should not have to be told twice.

C<data> walks this, so the fragment does not have to call C<restore_state>
itself.  Keyed on the destination because that is what has to be unique: two
recipes restoring different things to the same path is a disagreement, and
C<reconcile> is where it gets settled rather than silently resolved.

B<Not derived from C<remote_files>.>  It looks like the inverse and often is,
but not always: C<mail> salvages C</mail/keys> whole and puts one subdirectory
of it back at C</etc/opendkim/keys/$domain>, which no rule about reversing the
map would produce.  Restoring state to the wrong place is destructive, so this
is said outright rather than inferred.

Leave it empty -- which is the default -- for a recipe whose salvage lands in
the domain directory the service already reads from, since the C<data> target
has then already put it where it goes.

A recipe whose destination is owned by a service that is running before the
makefile starts cannot use this: the restore has to happen between a stop and a
start inside that recipe's own target.  C<redis> and C<plexmediaserver> are the
two, and they keep their own C<restore_state> calls.

=cut

sub restores {
    my ( $self, %opts ) = @_;
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

Which is also the reason C<remote_skip> exists: a directory salvaged wholesale is
a directory that ends up in that tarball, and some of what lives in one is meant
to stay on the machine it was made on.

=head4 Naming it is half of it

What C<remote_files> names comes back down and goes back up, and lands under
C<install_dir/domain> with everything else in the data directory.  If the
service reads it somewhere else, the fragment has to put it there:

    [% script_dir %]/restore_state '[% install_dir %]/[% domain %]/pdns' /var/spool/powerdns pdns:pdns

C<restore_state> declines when nothing was salvaged, when what was salvaged is
empty -- which is what a fetch that could not read the directory leaves -- and
when the destination already has state in it, which is what keeps
re-provisioning a live guest from writing a partial copy over the real thing.
Call it before the service starts.

A recipe whose state already lives under C<install_dir/domain> needs none of
this: the data target puts it back where it came from.  That is the reason to
keep state there when the software will let you.

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
    return $self->render_raw( $file, $self->validated( $self->vars(), @_ ) );
}

=head3 $output = $recipe->render_raw($file, %template_vars)

Render a template against variables that have B<already> been through
C<validate>.

C<render_file> is the one to call.  This is for the one caller that cannot:
C<enrich>, which runs inside C<validate> and so cannot ask for a render that
validates -- C<render_file> would re-enter C<validate>, which would call
C<enrich>, which would ask for another render.

Which a recipe needs when one of its generated files has to appear inside
another.  A distro's cloud-init carries the setup script by value, in a
C<write_files> entry, so the script has to be rendered before the user-data
that quotes it -- and the answer is a template variable rather than an ordering
between two C<template_files> entries, because nothing about C<template_files>
promises an order.

=cut

sub render_raw {
    my ( $self, $file, %vars ) = @_;
    return $self->{tt}->render( $file, \%vars );
}

=head3 @written = $recipe->generate_files($output_dir, %template_vars)

Render everything in C<template_files> into C<$output_dir>, and hand back what
was written, relative to it.

A name ending in C<.tt> is rendered and anything else is copied, which is what
C<template_files> already documents.  Both callers are here rather than in one
of them: C<bin/new_config> generates a recipe's files while it walks the
modules, and C<bin/provision> generates the ones that cannot be written until a
hypervisor has answered for itself -- see C<Provisioner::Recipe::vm>.

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

Where a template actually is, out of C<template_dirs>, or dies naming what it
looked through.

The renderer finds a template by name on its own; this is for the ones that are
not rendered -- a file with no variables in it, which C<template_files> copies
rather than renders -- and for a caller that has to hand the path to something
else.

=cut

sub template_path {
    my ( $self, $file ) = @_;

    foreach my $dir ( @{ $self->{template_dirs} } ) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        return "$dir/$file" if -f "$dir/$file";
    }

    die "Could not find the template $file in " . join( ', ', @{ $self->{template_dirs} } ) . "\n";
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
