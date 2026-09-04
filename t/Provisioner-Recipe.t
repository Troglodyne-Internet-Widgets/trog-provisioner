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

subtest 'schema defaults are filled in, because nothing else fills them' => sub {
    # JSON::Validator checks data against a schema and fills nothing in, so a
    # default in args() documented an intention nobody carried out.  chrony
    # refused to start over a makestep with no arguments after it.
    my %schema = (
        type       => 'object',
        properties => {
            plain    => { type => 'string',  default => 'a default' },
            given    => { type => 'string',  default => 'a default' },
            emptied  => { type => 'string',  default => 'a default' },
            listed   => { type => 'array',   default => [qw{one two}] },
            nodefault=> { type => 'string' },
            nested   => {
                type       => 'object',
                properties => { inner => { type => 'string', default => 'inner default' } },
            },
        },
    );

    my %opts = (given => 'mine', emptied => undef, nested => { });
    Provisioner::Recipe::apply_defaults(\%opts, \%schema);

    is($opts{plain}, 'a default', 'an absent field gets its default');
    is($opts{given}, 'mine',      'one that was given does not');

    # `makestep:` with nothing after it in YAML is how somebody says "whatever
    # you think", not "empty".
    is($opts{emptied}, 'a default', 'and an explicit undef is treated as absent');

    ok(!exists $opts{nodefault}, 'a field with no default is not invented');
    is_deeply($opts{listed}, [qw{one two}], 'lists come through');
    is($opts{nested}{inner}, 'inner default', 'and nested objects are filled too');

    my %other;
    Provisioner::Recipe::apply_defaults(\%other, \%schema);
    push @{ $opts{listed} }, 'mutated';
    is_deeply($other{listed}, [qw{one two}], 'a default is copied, not shared between recipes');
};

done_testing();
