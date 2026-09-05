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
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }
use File::Temp qw{tempdir};
use Test::More;

use_ok('Provisioner::Recipe');

subtest "Ensure global/doman specific templates are rendered correctly" => sub {
    my $tdir = tempdir( CLEANUP => 1 );

    # Build minimal recipe objects by blessing directly so has_global_template
    # works without needing a live Text::Xslate instance.
    my $with_global = bless {
        template        => 'widget.tt',
        global_template => 'widget.global.tt',
        template_dirs   => [$tdir],
    }, 'Provisioner::Recipe';

    my $without_global = bless {
        template        => 'noglobal.tt',
        global_template => 'noglobal.global.tt',
        template_dirs   => [$tdir],
    }, 'Provisioner::Recipe';

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
        template_dirs   => [$tdir, $tdir2],
    }, 'Provisioner::Recipe';
    ok( $multi_dir->has_global_template(), 'has_global_template searches all template_dirs' );

    # Rendering tests - need a full recipe object via new()
    open my $tt_fh, '>', "$tdir/widget.tt" or die $!;
    print $tt_fh "domain=[% domain %]\n";
    close $tt_fh;

    my $recipe = bless {
        template        => 'widget.tt',
        global_template => 'widget.global.tt',
        template_dirs   => [$tdir],
        tt              => Text::Xslate->new({
            path   => [$tdir],
            syntax => 'TTerse',
            module => ['Text::Xslate::Bridge::TT2'],
        }),
    }, 'Provisioner::Recipe';

    my $global_out = $recipe->render_global( global_flag => 'yes' );
    like( $global_out, qr/global_setup=yes/, 'render_global renders global template' );

    my $domain_out = $recipe->render( domain => 'example.com' );
    like( $domain_out, qr/domain=example\.com/, 'render still renders per-domain template' );
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

    my %opts = (given => 'mine', emptied => undef, blank => undef);
    Provisioner::Recipe::forget_undefs(\%opts, \%schema);

    # The validator fills a default in when the key is absent, which is the
    # right rule for JSON and the wrong one for YAML: "emptied:" with nothing
    # after it means "whatever you think", not "empty".
    ok(!exists $opts{emptied}, 'a field named and left empty is dropped, so the default can land');
    ok(exists $opts{blank} && !defined $opts{blank},
        'one with no default to land is left alone, since unset may mean something');

    my $validator = JSON::Validator::Schema::Troglodyne->new->coerce('defaults');
    $validator->validate(\%opts, \%schema);

    is($opts{plain},   'a default', 'an absent field gets its default');
    is($opts{emptied}, 'a default', 'and so does one that was emptied');
    is($opts{given},   'mine',      'one that was given does not');
    ok(!exists $opts{nodefault}, 'a field with no default is not invented');
    is_deeply($opts{listed}, [qw{one two}], 'lists come through');
};

subtest 'a recipe gets its declared defaults end to end' => sub {
    require Provisioner::Recipe::ntp;
    my $r = 'Provisioner::Recipe::ntp'->new(template_dirs => ['templates'], output_dir => '/tmp');

    my %v = $r->validate(domain => 'd.test');
    is($v{makestep}, '1.0 3', 'through validate(), which is what render_file calls');
    ok(scalar @{ $v{servers} }, 'including the list of time sources');

    my %u = $r->validate(domain => 'd.test', makestep => undef);
    is($u{makestep}, '1.0 3', 'and an explicitly empty one still gets it');
};

{
    # Counts what validate() actually did, since the point of a memo is the
    # work it does not do.
    package Test::Recipe::Memo;
    our @ISA = ('Provisioner::Recipe');
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
        my ($self, %opts) = @_;
        $enriched++;
        $opts{seen} = $opts{flavour};
        return %opts;
    }
}

subtest 'validated() memoizes, per object and per set of options' => sub {
    my $one = bless {}, 'Test::Recipe::Memo';
    local $Test::Recipe::Memo::enriched = 0;

    my %first  = $one->validated(domain => 'a.test', flavour => 'first');
    my %again  = $one->validated(domain => 'a.test', flavour => 'first');
    is($Test::Recipe::Memo::enriched, 1, 'the same options enrich once, however often they are rendered');
    is($again{seen}, 'first', 'and the second render gets the memoized answer');

    # Keyed on the options because one object really is rendered with more than
    # one set: t/recipes.t renders cron's root crontab twice, with a bare local
    # part and with a full address, and expects the two to differ.  A memo that
    # ignored its arguments would answer the second with the first.
    my %other = $one->validated(domain => 'a.test', flavour => 'second');
    is($other{seen}, 'second', 'different options are validated again');
    is($Test::Recipe::Memo::enriched, 2, 'so enrich runs a second time for them');

    # On the object, not in a state variable: state in a named sub is one
    # variable for the sub rather than one per object, and new_config configures
    # several domains in a single run, each with its own recipe objects.
    my $two = bless {}, 'Test::Recipe::Memo';
    my %theirs = $two->validated(domain => 'b.test', flavour => 'third');
    is($theirs{domain}, 'b.test', q{a second object of the same class does not inherit the first one's answer});
};

done_testing();
