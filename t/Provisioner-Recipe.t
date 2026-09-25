#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe.t - the recipe base class

=cut

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it
use File::Temp qw{tempdir};
use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use_ok('Provisioner::Recipe');
use Provisioner::Cookbook();
use Provisioner::Recipe();

subtest "Ensure global/doman specific templates are rendered correctly" => sub {
    my $tdir = tempdir( CLEANUP => 1 );

    # Build minimal recipe objects by blessing directly so has_global_template
    # works without needing a live Text::Xslate instance.
    my $with_global = bless {
        template        => 'widget.tt',
        global_template => 'widget.global.tt',
        template_dirs   => [$tdir],
      },
      'Provisioner::Recipe';

    my $without_global = bless {
        template        => 'noglobal.tt',
        global_template => 'noglobal.global.tt',
        template_dirs   => [$tdir],
      },
      'Provisioner::Recipe';

    # has_global_template - no .global.tt yet
    ok( !$with_global->has_global_template(),    'has_global_template false when file absent' );
    ok( !$without_global->has_global_template(), 'has_global_template false for noglobal recipe' );

    # Create the global template file
    open my $fh, '>', "$tdir/widget.global.tt" or die $!;
    print {$fh} "global_setup=[% admin_user %]\n";
    close($fh) or die "Could not close $tdir/widget.global.tt: $!";

    ok( $with_global->has_global_template(),     'has_global_template true after file created' );
    ok( !$without_global->has_global_template(), 'has_global_template still false for noglobal recipe' );

    # Multiple template dirs - found in second dir
    my $tdir2 = tempdir( CLEANUP => 1 );
    open my $fh2, '>', "$tdir2/other.global.tt" or die $!;
    print {$fh2} "other\n";
    close($fh2) or die "Could not close $tdir2/other.global.tt: $!";

    my $multi_dir = bless {
        template        => 'other.tt',
        global_template => 'other.global.tt',
        template_dirs   => [ $tdir, $tdir2 ],
      },
      'Provisioner::Recipe';
    ok( $multi_dir->has_global_template(), 'has_global_template searches all template_dirs' );

    # Rendering tests - need a full recipe object via new()
    open my $tt_fh, '>', "$tdir/widget.tt" or die $!;
    print {$tt_fh} "domain=[% domain %]\n";
    close($tt_fh) or die "Could not close $tdir/widget.tt: $!";

    # One per configuration, as new_config builds them: validated() memoizes on
    # the object, so the two renders below are two objects rather than one asked
    # two different things.
    my $widget = sub {
        return bless {
            template        => 'widget.tt',
            global_template => 'widget.global.tt',
            template_dirs   => [$tdir],
            tt              => Text::Xslate->new(
                {
                    path   => [$tdir],
                    syntax => 'TTerse',
                    module => ['Text::Xslate::Bridge::TT2'],
                }
            ),
          },
          'Provisioner::Recipe';
    };

    my $global_out = $widget->()->render_global( admin_user => 'yes' );
    like( $global_out, qr/global_setup=yes/, 'render_global renders global template' );

    my $domain_out = $widget->()->render( domain => 'example.test' );
    like( $domain_out, qr/domain=example\.test/, 'render still renders per-domain template' );
};

# Every recipe is handed the same set of settings by bin/new_config, and
# Provisioner::Recipe::global_args is where they are declared -- once, rather
# than absorbed one at a time into the recipes that got tired of them rendering
# empty.
subtest 'the settings every recipe is handed are declared once' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my %prov = ( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );

    my $ntp = Provisioner::Cookbook->load( 'ntp', distro => 'ubuntu' )->new(%prov);
    my %got = $ntp->validate( domain => 'x.test.test', admin_user => 'someadmin', transfer_port => '22', main_ip => undef, gateway => undef );

    # A port written in the configuration with quotes around it arrives as the
    # string it was written as.
    is( $got{transfer_port}, 22, 'a port written as a string comes out an integer' );

    # Both genuinely absent where the hypervisor addresses its own guests, so
    # the declaration says nullable and this is what that buys.
    ok( exists $got{main_ip} && !defined $got{main_ip}, 'an address the hypervisor has not allocated is accepted as absent' );

    # The same state, and the one this got wrong first: a cloud guest has no
    # gateway of ours, and Provisioner::Recipe::ubuntu asks for one only where
    # there are ips.  Declared without nullable, that was refused outright.
    ok( exists $got{gateway} && !defined $got{gateway}, 'and so is a gateway the platform provides instead' );

    # user is not declared with a default anywhere, so this fallback -- which
    # runs after validation -- is still what fills it in.
    is( $got{user}, 'someadmin', 'user still falls back to admin_user' );
};

# A recipe that declares a colliding key is describing a different thing spelled
# the same, and it is the one that knows.  registrar's `user` is the account at
# the registrar, not the service account, and its default of empty is precisely
# what stops validate filling it in from admin_user -- without which the lexicon
# shortcut exports an AUTH_USERNAME for a registrar that wants a token alone.
subtest 'a recipe that declares one of them keeps its own meaning' => sub {
    my $dir       = tempdir( CLEANUP => 1 );
    my $registrar = Provisioner::Cookbook->load( 'registrar', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %got = $registrar->validate( domain => 'x.test.test', type => 'easydns', admin_user => 'someadmin' );
    is( $got{user}, q{}, 'the registrar account stays empty rather than becoming the admin' );
};

# The declaration is deliberately not folded into args(): Provisioner::Cookbook
# spec() calls that, and bin/recipes, bin/new_guest --scaffold and
# DistroRecipe::global_defaults all read what it returns.  A global declared
# there would be offered as a field of every recipe to scaffold.
subtest 'and none of them is offered as a field of a recipe' => sub {
    my %spec   = Provisioner::Cookbook->spec('nginx');
    my $props  = $spec{properties} // {};
    my $global = { Provisioner::Recipe->global_args }->{properties};

    my @leaked = grep { exists $props->{$_} } sort keys %$global;
    is_deeply( \@leaked, [], 'bin/recipes nginx still says what nginx takes and nothing else' );
};

# A field nothing declares reached a template that never read it, so a
# misspelled key configured nothing and the build went green: the mistake
# surfaced whenever somebody noticed the thing they had configured was not
# configured.  pdns.soa and mail.to each sat in the live configuration doing
# exactly that.
subtest 'a key no schema declares is refused' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $ntp = Provisioner::Cookbook->load( 'ntp', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    is( { $ntp->schema() }->{additionalProperties}, 0, 'schema() says so for every recipe, rather than each one deciding' );

    my $err = exception { $ntp->validate( domain => 'x.test.test', admin_user => 'someadmin', makstep => '1.0 3' ) };
    like( $err, qr/makstep/,           'the refusal names the key nothing declares' );
    like( $err, qr/bin.recipes[ ]ntp/, 'and points at what would have told them what it takes' );

    is(
        exception { $ntp->validate( domain => 'x.test.test', admin_user => 'someadmin', makestep => '1.0 3' ) },
        undef, 'while the field it was a misspelling of is taken'
    );
};

# bin/new_config hands every recipe one hash of settings, and some of what
# travels in it is nobody's configuration: libdir is spent on @INC before a
# recipe exists, size and cpus belong to the machine.  Filtering per recipe is
# what lets global_args stay a list of what a recipe acts on rather than a list
# of everything that travels beside it.
subtest 'takes() hands a recipe only what it declares' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my %prov = (
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    my $ntp = Provisioner::Cookbook->load( 'ntp', distro => 'ubuntu' )->new(%prov);

    my %offered = (
        domain     => 'x.test.test',
        admin_user => 'someadmin',
        libdir     => ['/opt/vendor'],
        size       => '50%',
        cpus       => 2,
    );

    my %kept = $ntp->takes(%offered);
    is_deeply( [ sort keys %kept ], [qw{admin_user domain}], 'the settings it declares survive' );
    is( $kept{domain}, 'x.test.test', 'with the values they came with' );

    # The two halves compose: strictness is only survivable because a recipe is
    # handed what it declares, and filtering is only worth doing because the
    # schema refuses the rest.
    is( exception { $ntp->validate(%kept) }, undef, 'so what a recipe is handed validates' );
    ok( exception { $ntp->validate(%offered) }, 'where the hash it was filtered out of would not' );

    # Per recipe, not one list of exemptions: tmpfs means its own thing by size
    # and is handed it.
    my %tmpfs_kept = Provisioner::Cookbook->load( 'tmpfs', distro => 'ubuntu' )->new(%prov)->takes(%offered);
    is( $tmpfs_kept{size}, '50%', 'a recipe that declares one of them gets it' );
};

subtest 'schema defaults are filled in' => sub {

    # JSON::Validator does this itself, at Schema.pm:758 -- but only under
    # coerce('defaults'), and OpenAPIv3 coerces booleans, numbers and strings
    # without it.  Nothing turned it on, so every default in every args()
    # documented an intention that never happened: chrony got a makestep with no
    # arguments after it and refused to start.
    my %schema = (
        type       => 'object',
        properties => {
            plain     => { type => 'string', default => 'a default' },
            given     => { type => 'string', default => 'a default' },
            emptied   => { type => 'string', default => 'a default' },
            listed    => { type => 'array',  default => [qw{one two}] },
            nodefault => { type => 'string' },
            blank     => { type => 'string' },
        },
    );

    my %opts = ( given => 'mine', emptied => undef, blank => undef );
    Provisioner::Recipe::forget_undefs( \%opts, \%schema );

    # The validator fills a default in when the key is absent, which is the
    # right rule for JSON and the wrong one for YAML: "emptied:" with nothing
    # after it means "whatever you think", not "empty".
    ok( !exists $opts{emptied}, 'a field named and left empty is dropped, so the default can land' );
    ok(
        exists $opts{blank} && !defined $opts{blank},
        'one with no default to land is left alone, since unset may mean something'
    );

    my $validator = JSON::Validator::Schema::Troglodyne->new->coerce('defaults');
    $validator->validate( \%opts, \%schema );

    is( $opts{plain},   'a default', 'an absent field gets its default' );
    is( $opts{emptied}, 'a default', 'and so does one that was emptied' );
    is( $opts{given},   'mine',      'one that was given does not' );
    ok( !exists $opts{nodefault}, 'a field with no default is not invented' );
    is_deeply( $opts{listed}, [qw{one two}], 'lists come through' );
};

subtest 'a recipe gets its declared defaults end to end' => sub {
    require Provisioner::Recipe::ntp;
    my $r = 'Provisioner::Recipe::ntp'->new( template_dirs => ['templates'], output_dir => '/tmp' );

    my %v = $r->validate( domain => 'd.test' );
    is( $v{makestep}, '1.0 3', 'through validate(), which is what render_file calls' );
    ok( scalar @{ $v{servers} }, 'including the list of time sources' );

    my %u = $r->validate( domain => 'd.test', makestep => undef );
    is( $u{makestep}, '1.0 3', 'and an explicitly empty one still gets it' );
};

{
    # Counts what validate() actually did, since the point of a memo is the
    # work it does not do.
    package Test::Recipe::Memo;
    our @ISA      = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA) -- a class declared in the test, with no file behind it
    our $enriched = 0;

    sub args {
        return (
            type       => 'object',
            properties => {
                domain  => { type => 'string' },
                flavour => { type => 'string' },
            },
        );
    }

    sub enrich {
        my ( $self, %opts ) = @_;
        $enriched++;
        $opts{seen} = $opts{flavour};
        return %opts;
    }
}

subtest 'validated() memoizes for the life of the recipe object' => sub {
    my $one = bless {}, 'Test::Recipe::Memo';
    local $Test::Recipe::Memo::enriched = 0;

    $one->validated( domain => 'a.test', flavour => 'first' );
    my %again = $one->validated( domain => 'a.test', flavour => 'first' );
    is( $Test::Recipe::Memo::enriched, 1,       'one object enriches once, however often it is rendered' );
    is( $again{seen},                  'first', 'and every render after the first gets that answer' );

    # A recipe object is one domain's worth of one recipe, so its memo has to go
    # when it does.  A cache that outlived it would answer a configuration that
    # ought to be rejected from the last one that validated, and the die that
    # t/recipes.t's rejects_missing is checking for would never happen.
    # Same class and the same domain as the first, which is the case that tells
    # an object-scoped memo from a cache keyed on either of those: a rebuilt
    # recipe has to be validated afresh, not answered from its predecessor.
    my $two    = bless {}, 'Test::Recipe::Memo';
    my %theirs = $two->validated( domain => 'a.test', flavour => 'second' );
    is( $theirs{seen},                 'second', q{a second object of the same class and domain gets its own answer} );
    is( $Test::Recipe::Memo::enriched, 2,        'and enriches for itself' );

    # A third domain, to say the same thing about the axis new_config varies.
    my $three = bless {}, 'Test::Recipe::Memo';
    my %other = $three->validated( domain => 'b.test', flavour => 'third' );
    is( $other{domain}, 'b.test', 'and so does one built for another domain' );
};

{
    # A recipe of no distribution, named as a recipe because new() works out
    # the fragment from the name.
    package Provisioner::Recipe::nametest;
    our @ISA = ('Provisioner::Recipe');    ## no critic (ClassHierarchies::ProhibitExplicitISA) -- a class declared in the test, with no file behind it
}

subtest 'recipe_name is the last component, whichever distro specialised it' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    is( 'Provisioner::Recipe::nametest'->recipe_name,                                                       'nametest', 'of a class' );
    is( 'Provisioner::Recipe::nametest'->new( template_dirs => [$tdir], output_dir => $tdir )->recipe_name, 'nametest', 'of an object' );
    is( Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->recipe_name,                            'nginx',    'and of a distribution version of a recipe, which shares the fragment' );
    is( Provisioner::Recipe->recipe_name,                                                                   undef,      'and nothing for a class that is not one' );
};

subtest 'reconcile() hands disagreements to the recipe, and dies by default' => sub {
    my $r = bless {}, 'Provisioner::Recipe';

    # Only what the two actually disagree about: a field one of them never
    # mentioned is already whatever the merge left.
    my $merged = { port => 80, name => 'a', nested => { deep => 1, mine => 'kept' } };
    $r->reconcile( $merged, { port => 80, nested => { deep => 1 } } );
    is_deeply(
        $merged,
        { port => 80, name => 'a', nested => { deep => 1, mine => 'kept' } },
        'agreeing on everything changes nothing'
    );

    # Structure belongs to the merge; this only settles scalars.
    my $lists = { hosts => ['a'], nested => { hosts => ['b'] } };
    is(
        exception { $r->reconcile( $lists, { hosts => ['c'], nested => { hosts => ['d'] } } ) },
        undef, 'arrays are left to the merge rather than fought over'
    );

    like(
        exception { $r->reconcile( { port => 80 }, { port => 443 } ) },
        qr/Two[ ]recipes[ ]want[ ]different[ ]things.*port[ ]is[ ]'80'.*'443'/,    ## no critic (RegularExpressions::ProhibitComplexRegexes)
        'a scalar two dependents disagree about dies, naming both values'
    );

    # The path is what somebody has to go and set, so it has to be the whole path.
    like(
        exception { $r->reconcile( { tls => { port => 80 } }, { tls => { port => 443 } } ) },
        qr/tls\.port/,
        'and names the nested field by its full path'
    );

    like(
        exception { $r->reconcile( { port => 80 }, { port => 443 } ) },
        qr/set[ ]port[ ]explicitly[ ]under/,
        'and says what to do about it'
    );
};

subtest 'a distribution version of a recipe answers to the same name' => sub {
    my $tdir = tempdir( CLEANUP => 1 );

    {

        package Provisioner::Recipe::widget;
        use parent -norequire, 'Provisioner::Recipe';
    }
    {

        package Provisioner::Recipe::Ubuntu::widget;
        use parent -norequire, 'Provisioner::Recipe::widget';
    }

    # The name is taken from the last component of the class, so a subclass
    # renders the same fragment as the recipe it specializes.  Sharing the
    # fragment is the point: what a distribution changes is deps.
    my $specific = 'Provisioner::Recipe::Ubuntu::widget'->new( template_dirs => [$tdir], output_dir => $tdir );
    is( $specific->{template},        'widget.tt',        'the subclass looks for the recipe fragment' );
    is( $specific->{global_template}, 'widget.global.tt', 'and its global one' );

    {

        package Provisioner::Recipe::Ubuntu::Deeper::widget;
        use parent -norequire, 'Provisioner::Recipe::widget';
    }
    like(
        exception { 'Provisioner::Recipe::Ubuntu::Deeper::widget'->new( template_dirs => [$tdir], output_dir => $tdir ) },
        qr/Could[ ]not[ ]extract[ ]recipe[ ]name/,
        'but only one level deep, so a class name that is not a recipe name is refused'
    );
};

subtest 'render_raw renders without going back through validate' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    open( my $fh, '>', "$tdir/inner.tt" ) or die $!;
    print {$fh} 'inner sees [% thing %]';
    close($fh) or die "Could not close $tdir/inner.tt: $!";

    # What an enrich needs: it runs inside validate, so asking for a render that
    # validates would call it again, and again.  This one asserts that by
    # counting -- an enrich that recursed would never finish.
    {

        package Provisioner::Recipe::embedder;
        use parent -norequire, 'Provisioner::Recipe';

        # A package variable rather than a closed-over lexical: a named sub does
        # not close over one declared in an enclosing block at runtime.
        our $CALLS = 0;

        # Declared because the render below passes it: a recipe refuses a field
        # no schema of its own names.
        sub args {
            return ( type => 'object', properties => { thing => { type => 'string' } } );
        }

        sub enrich {
            my ( $self, %opts ) = @_;
            $CALLS++;
            $opts{embedded} = $self->render_raw( 'inner.tt', %opts );
            return %opts;
        }
    }

    my $r = 'Provisioner::Recipe::embedder'->new( template_dirs => [$tdir], output_dir => $tdir );
    open( $fh, '>', "$tdir/embedder.tt" ) or die $!;
    print {$fh} 'outer got: [% embedded %]';
    close($fh) or die "Could not close $tdir/embedder.tt: $!";

    is( $r->render( thing => 'a value' ),      'outer got: inner sees a value', 'a recipe can put one of its templates inside another' );
    is( $Provisioner::Recipe::embedder::CALLS, 1,                               'and enrich ran once rather than recursing' );
};

subtest 'generate_files writes what template_files names' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    my $out  = tempdir( CLEANUP => 1 );

    mkdir "$tdir/files";
    open( my $fh, '>', "$tdir/files/gen.rendered.tt" ) or die $!;
    print {$fh} 'for [% domain %]';
    close($fh) or die "Could not close $tdir/files/gen.rendered.tt: $!";

    # A name that does not end in .tt is copied rather than rendered, which is
    # what you want for something with no variables in it.
    open( $fh, '>', "$tdir/files/gen.verbatim.conf" ) or die $!;
    print {$fh} 'left [% alone %]';
    close($fh) or die "Could not close $tdir/files/gen.verbatim.conf: $!";

    {

        package Provisioner::Recipe::gen;
        use parent -norequire, 'Provisioner::Recipe';

        sub template_files {
            return ( 'gen.rendered.tt' => 'rendered.conf', 'gen.verbatim.conf' => 'verbatim.conf' );
        }
    }

    my @written = 'Provisioner::Recipe::gen'->new( template_dirs => [$tdir], output_dir => $out )->generate_files( $out, domain => 'vm.example.test' );

    is_deeply( [ sort @written ], [qw{rendered.conf verbatim.conf}], 'and says what it wrote, relative to where' );
    is( File::Slurper::read_text("$out/rendered.conf"), 'for vm.example.test', 'a .tt is rendered' );
    is( File::Slurper::read_text("$out/verbatim.conf"), 'left [% alone %]',    'and anything else is copied' );
};

subtest 'each port a recipe binds is claimed for it, from ufw' => sub {
    {

        package Provisioner::Recipe::claimant;
        use parent -norequire, 'Provisioner::Recipe';
        sub rate_limits { return ( 80 => 1024, '53/udp' => 64 ) }
        sub listens { return ( '3000/tcp', 8086 ) }
    }
    {

        package Provisioner::Recipe::quiet;
        use parent -norequire, 'Provisioner::Recipe';
        sub listens { return 5432 }
    }

    my %req = Provisioner::Recipe::required_recipes('Provisioner::Recipe::claimant');
    ok( $req{ufw}, 'a recipe that binds ports requires ufw' ) or return;
    my %ufw   = $req{ufw}->();
    my %every = ( q{::} => { claimant => 1 } );
    is_deeply(
        $ufw{listeners},
        { 80 => {%every}, '53/udp' => {%every}, 3000 => {%every}, 8086 => {%every} },
        'claiming what it rate limits and what it only binds, on every address, under its own name, with tcp written bare'
    );
    is_deeply( $ufw{rate_limits}, { 80 => 1024, '53/udp' => 64 }, 'and the limits go along unchanged' );

    my %quiet = Provisioner::Recipe::required_recipes('Provisioner::Recipe::quiet');
    ok( $quiet{ufw}, 'a port with no limit still requires ufw' ) or return;
    is_deeply( { $quiet{ufw}->() }, { rate_limits => {}, listeners => { 5432 => { q{::} => { quiet => 1 } } } }, 'with the claim and no limits' );

    my %none = Provisioner::Recipe::required_recipes('Provisioner::Recipe::nametest');
    ok( !$none{ufw}, 'and a recipe that binds nothing does not' );
};

subtest 'a claim carries the address it binds' => sub {
    my $mock   = Test::MockModule->new( 'Provisioner::Recipe::quiet', no_auto => 1 );
    my $claims = sub {
        my ( $limits, @listens ) = @_;
        $mock->redefine( rate_limits => sub { return %$limits } );
        $mock->redefine( listens     => sub { return @listens } );
        return { Provisioner::Recipe::claims('Provisioner::Recipe::quiet') };
    };

    is_deeply(
        $claims->( {}, qw{127.0.0.1:5432 [::1]:5432 [0:0:0:0:0:0:0:1]:5432 [::1]:323/udp} ),
        { 5432 => { '127.0.0.1' => { quiet => 1 }, '::1' => { quiet => 1 } }, '323/udp' => { '::1' => { quiet => 1 } } },
        'each address under its port, IPv6 without its brackets, and one address however it is spelled'
    );
    is_deeply(
        $claims->( {}, qw{127.0.0.1:80 0.0.0.0:80 [::]:443 [::1]:443} ),
        { 80 => { q{::} => { quiet => 1 } }, 443 => { q{::} => { quiet => 1 } } },
        'every address of either family is ::, and is the only claim on its port'
    );
    is_deeply(
        $claims->( { 6379 => 512, 53 => 64 }, '127.0.0.1:6379' ),
        { 6379 => { '127.0.0.1' => { quiet => 1 } }, 53 => { q{::} => { quiet => 1 } } },
        'a rate limit claims every address, unless listens names its port with an address'
    );

    foreach my $bad ( qw{::1:5432 [127.0.0.1]:5432 999.0.0.1:5432 localhost:5432 127.0.0.1:5432/sctp}, q{} ) {
        like( exception { $claims->( {}, $bad ) }, qr{quiet[ ]recipe[ ]claims}, "'$bad' is refused, naming the recipe" );
    }
};

subtest 'fragment_commands splits a fragment where make does' => sub {
    my $fragment = "one\ntwo \\\n    continued\nthree";
    my @commands = Provisioner::Recipe->fragment_commands($fragment);
    is_deeply( \@commands, [ "one\n", "two \\\n    continued\n", 'three' ], 'a continued line stays with its command' );
    is( join( q{}, @commands ), $fragment, 'and the commands join back into the fragment' );
};

subtest 'quiet_secrets puts an @ on each command that holds a secret' => sub {
    my $quiet = sub { return Provisioner::Recipe->quiet_secrets(@_) };

    is( $quiet->( "echo 'SeCrEt' > file\nls\n", 'SeCrEt' ),                                                 "\@echo 'SeCrEt' > file\nls\n", 'a command with the secret, and not the one without it' );
    is( $quiet->( "a \\\n    'SeCrEt'\nb\n",    'SeCrEt' ),                                                 "\@a \\\n    'SeCrEt'\nb\n",    'on the first line of a continued command, where make reads it' );
    is( $quiet->( "\@echo 'SeCrEt'\n",          'SeCrEt' ),                                                 "\@echo 'SeCrEt'\n",            'and only once' );
    is( $quiet->( "    echo SeCrEt\n",          'SeCrEt' ),                                                 "    \@echo SeCrEt\n",          'after the indentation, which tabinate turns into the tab' );
    is( $quiet->( "cat line-two-of-it\n",       "-----BEGIN KEY-----\nline-two-of-it\n-----END KEY-----" ), "\@cat line-two-of-it\n",       'a secret of several lines matches on any one of them' );

    my $plain = "echo nothing\n";
    is( $quiet->( $plain, 'SeCrEt' ),   $plain, 'a fragment with no secret in it is left as it is' );
    is( $quiet->($plain),               $plain, 'and so is any fragment, when there are no secrets' );
    is( $quiet->( $plain, q{}, undef ), $plain, 'and an empty secret matches nothing' );
};

done_testing();
