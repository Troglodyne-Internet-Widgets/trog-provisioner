#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

t/Provisioner-Recipe.t - the recipe base class

=cut

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }
use File::Temp qw{tempdir};
use Test::More;
use Test::Fatal qw{exception};
use IPC::Run3();

use_ok('Provisioner::Recipe');
use Provisioner::Cookbook();

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
    print $fh "global_setup=[% global_flag %]\n";
    close $fh;

    ok( $with_global->has_global_template(),     'has_global_template true after file created' );
    ok( !$without_global->has_global_template(), 'has_global_template still false for noglobal recipe' );

    # Multiple template dirs - found in second dir
    my $tdir2 = tempdir( CLEANUP => 1 );
    open my $fh2, '>', "$tdir2/other.global.tt" or die $!;
    print $fh2 "other\n";
    close $fh2;

    my $multi_dir = bless {
        template        => 'other.tt',
        global_template => 'other.global.tt',
        template_dirs   => [ $tdir, $tdir2 ],
      },
      'Provisioner::Recipe';
    ok( $multi_dir->has_global_template(), 'has_global_template searches all template_dirs' );

    # Rendering tests - need a full recipe object via new()
    open my $tt_fh, '>', "$tdir/widget.tt" or die $!;
    print $tt_fh "domain=[% domain %]\n";
    close $tt_fh;

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

    my $global_out = $widget->()->render_global( global_flag => 'yes' );
    like( $global_out, qr/global_setup=yes/, 'render_global renders global template' );

    my $domain_out = $widget->()->render( domain => 'example.test' );
    like( $domain_out, qr/domain=example\.test/, 'render still renders per-domain template' );
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
    our @ISA      = ('Provisioner::Recipe');
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

    my %first = $one->validated( domain => 'a.test', flavour => 'first' );
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
    our @ISA = ('Provisioner::Recipe');
}

subtest 'recipe_name is the last component, whichever distro specialised it' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    is( Provisioner::Recipe::nametest->recipe_name,                                                       'nametest', 'of a class' );
    is( Provisioner::Recipe::nametest->new( template_dirs => [$tdir], output_dir => $tdir )->recipe_name, 'nametest', 'of an object' );
    is( Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->recipe_name,                          'nginx',    'and of a distribution version of a recipe, which shares the fragment' );
    is( Provisioner::Recipe->recipe_name,                                                                 undef,      'and nothing for a class that is not one' );
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
        qr/Two recipes want different things.*port is '80'.*'443'/s,
        'a scalar two dependants disagree about dies, naming both values'
    );

    # The path is what somebody has to go and set, so it has to be the whole path.
    like(
        exception { $r->reconcile( { tls => { port => 80 } }, { tls => { port => 443 } } ) },
        qr/tls\.port/,
        'and names the nested field by its full path'
    );

    like(
        exception { $r->reconcile( { port => 80 }, { port => 443 } ) },
        qr/set port explicitly under/,
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
    # renders the same fragment as the recipe it specialises.  Sharing the
    # fragment is the point: what a distribution changes is deps.
    my $specific = Provisioner::Recipe::Ubuntu::widget->new( template_dirs => [$tdir], output_dir => $tdir );
    is( $specific->{template},        'widget.tt',        'the subclass looks for the recipe fragment' );
    is( $specific->{global_template}, 'widget.global.tt', 'and its global one' );

    {

        package Provisioner::Recipe::Ubuntu::Deeper::widget;
        use parent -norequire, 'Provisioner::Recipe::widget';
    }
    like(
        exception { Provisioner::Recipe::Ubuntu::Deeper::widget->new( template_dirs => [$tdir], output_dir => $tdir ) },
        qr/Could not extract recipe name/,
        'but only one level deep, so a class name that is not a recipe name is refused'
    );
};

subtest 'render_raw renders without going back through validate' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    open( my $fh, '>', "$tdir/inner.tt" ) or die $!;
    print $fh 'inner sees [% thing %]';
    close $fh;

    # What an enrich needs: it runs inside validate, so asking for a render that
    # validates would call it again, and again.  This one asserts that by
    # counting -- an enrich that recursed would never finish.
    {

        package Provisioner::Recipe::embedder;
        use parent -norequire, 'Provisioner::Recipe';

        # A package variable rather than a closed-over lexical: a named sub does
        # not close over one declared in an enclosing block at runtime.
        our $CALLS = 0;

        sub enrich {
            my ( $self, %opts ) = @_;
            $CALLS++;
            $opts{embedded} = $self->render_raw( 'inner.tt', %opts );
            return %opts;
        }
    }

    my $r = Provisioner::Recipe::embedder->new( template_dirs => [$tdir], output_dir => $tdir );
    open( $fh, '>', "$tdir/embedder.tt" ) or die $!;
    print $fh 'outer got: [% embedded %]';
    close $fh;

    is( $r->render( thing => 'a value' ),      'outer got: inner sees a value', 'a recipe can put one of its templates inside another' );
    is( $Provisioner::Recipe::embedder::CALLS, 1,                               'and enrich ran once rather than recursing' );
};

subtest 'generate_files writes what template_files names' => sub {
    my $tdir = tempdir( CLEANUP => 1 );
    my $out  = tempdir( CLEANUP => 1 );

    mkdir "$tdir/files";
    open( my $fh, '>', "$tdir/files/gen.rendered.tt" ) or die $!;
    print $fh 'for [% domain %]';
    close $fh;

    # A name that does not end in .tt is copied rather than rendered, which is
    # what you want for something with no variables in it.
    open( $fh, '>', "$tdir/files/gen.verbatim.conf" ) or die $!;
    print $fh 'left [% alone %]';
    close $fh;

    {

        package Provisioner::Recipe::gen;
        use parent -norequire, 'Provisioner::Recipe';

        sub template_files {
            return ( 'gen.rendered.tt' => 'rendered.conf', 'gen.verbatim.conf' => 'verbatim.conf' );
        }
    }

    my @written = Provisioner::Recipe::gen->new( template_dirs => [$tdir], output_dir => $out )->generate_files( $out, domain => 'vm.example.test' );

    is_deeply( [ sort @written ], [qw{rendered.conf verbatim.conf}], 'and says what it wrote, relative to where' );
    is( File::Slurper::read_text("$out/rendered.conf"), 'for vm.example.test', 'a .tt is rendered' );
    is( File::Slurper::read_text("$out/verbatim.conf"), 'left [% alone %]',    'and anything else is copied' );
};

subtest 'host_of reads the host out of the forms a repo_url takes' => sub {
    my $recipe = 'Provisioner::Recipe';

    is( $recipe->host_of('https://github.com/o/r.git'),      'github.com', 'an https clone URL' );
    is( $recipe->host_of('https://gitea.test:3000/api/v1/'), 'gitea.test', 'a port is not part of the host' );
    is( $recipe->host_of('HTTPS://GitHub.COM/o/r'),          'github.com', 'and the case it was written in is not either' );

    # URI reads no host out of an scp-style address, and somebody will certainly
    # configure one: it is what gogs hands out.
    is( $recipe->host_of('git@github.com:o/r.git'),       'github.com', 'an scp-style git address, which is not a URL' );
    is( $recipe->host_of('ssh://git@gitea.test/o/r.git'), 'gitea.test', 'and an ssh one, which is' );

    is( $recipe->host_of('not a url'), undef, 'something that names no host' );
    is( $recipe->host_of(q{}),         undef, 'and nothing at all' );
    is( $recipe->host_of(undef),       undef, 'without warning about it' );
};

done_testing();
