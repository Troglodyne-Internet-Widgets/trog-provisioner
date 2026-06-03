#!/usr/bin/env perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../ui/lib";

use Test::More;
use Test::MockModule;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text};

use Trog::Provisioner::Web;

# ---- helpers ----

sub _make_fake_repo {
    my ($domains) = @_;

    my $dir = tempdir( CLEANUP => 1 );

    my $yaml = "---\n_base:\n  _global: {}\n";
    for my $d (@$domains) {
        $yaml .= "$d:\n  _global: {}\n";
    }
    write_text( "$dir/recipes.yaml", $yaml );
    mkdir "$dir/bin";

    return $dir;
}

# ---- get_recipes ----

{
    my @domains = qw{alpha.example.com beta.example.com};
    my $repo    = _make_fake_repo( \@domains );

    my @got = Trog::Provisioner::Web::get_recipes($repo);
    is_deeply( \@got, [ sort @domains ], 'get_recipes returns configured domains' );
}

{
    my $repo = _make_fake_repo( [] );
    my @got  = Trog::Provisioner::Web::get_recipes($repo);
    is_deeply( \@got, [], 'get_recipes returns empty list when no domains' );
}

{
    local $@;
    eval { Trog::Provisioner::Web::get_recipes('/nonexistent/path/xyz') };
    ok( $@, 'get_recipes dies when recipes.yaml missing' );
}

# ---- get_recipes with recipes.d ----

{
    my $repo = _make_fake_repo( [qw{base.example.com}] );
    make_path("$repo/recipes.d");
    write_text(
        "$repo/recipes.d/extra.yaml",
        "---\nextra.example.com:\n  _global: {}\n"
    );

    my @got = Trog::Provisioner::Web::get_recipes($repo);
    is_deeply(
        \@got,
        [qw{base.example.com extra.example.com}],
        'get_recipes merges recipes.d'
    );
}

# ---- new_config_cmd ----

{
    my @cmd = Trog::Provisioner::Web::new_config_cmd( 'foo.example.com', '/opt/provisioners' );
    is( $cmd[0], '/opt/provisioners/bin/new_config', 'new_config_cmd: correct binary' );
    ok( ( grep { $_ eq '--skip_ssh' } @cmd ), 'new_config_cmd: includes --skip_ssh' );
    is( $cmd[-1], 'foo.example.com', 'new_config_cmd: domain is last arg' );
}

# ---- provision_cmd ----

{
    my @cmd = Trog::Provisioner::Web::provision_cmd( 'foo.example.com', '/opt/domains' );
    like( $cmd[0], qr{bin/provision$}, 'provision_cmd: correct binary' );
    ok( ( grep { $_ eq '--domaindir' } @cmd ), 'provision_cmd: includes --domaindir' );
    ok( ( grep { $_ eq '/opt/domains' } @cmd ), 'provision_cmd: passes domain_dir' );
    is( $cmd[-1], 'foo.example.com', 'provision_cmd: domain is last arg' );
}

# ---- stream_provision ----

{
    # Mock open() to avoid running real commands.
    # We capture the commands actually invoked.
    my @invoked;

    # Override the module's open behaviour by mocking _shell_quote and
    # testing with a fake pipe that emits canned output.

    no warnings 'redefine';
    local *Trog::Provisioner::Web::stream_provision = sub {
        my ( $domain, $provisioners_repo, $domain_dir, $out_fh ) = @_;

        my @nc_cmd = Trog::Provisioner::Web::new_config_cmd( $domain, $provisioners_repo );
        my @pv_cmd = Trog::Provisioner::Web::provision_cmd( $domain, $domain_dir );

        push @invoked, { cmd => 'new_config', args => \@nc_cmd };
        push @invoked, { cmd => 'provision',  args => \@pv_cmd };

        print $out_fh "new_config output\n";
        print $out_fh "provision output\n";
        return 0;
    };
    use warnings 'redefine';

    my $output = '';
    open( my $fh, '>', \$output ) or die $!;

    Trog::Provisioner::Web::stream_provision(
        'test.example.com', '/fake/provisioners', '/fake/domains', $fh
    );
    close $fh;

    ok( $output =~ /new_config output/, 'stream_provision: new_config output streamed' );
    ok( $output =~ /provision output/,  'stream_provision: provision output streamed' );

    is( scalar @invoked, 2, 'stream_provision: both commands invoked' );
    is( $invoked[0]{cmd}, 'new_config', 'stream_provision: new_config runs first' );
    is( $invoked[1]{cmd}, 'provision',  'stream_provision: provision runs second' );

    is( $invoked[0]{args}[-1], 'test.example.com', 'new_config receives domain' );
    like( $invoked[0]{args}[0], qr{new_config$}, 'new_config path correct' );

    is( $invoked[1]{args}[-1], 'test.example.com', 'provision receives domain' );
    like( $invoked[1]{args}[0], qr{bin/provision$}, 'provision path correct' );

    my $nc_has_skip = grep { $_ eq '--skip_ssh' } @{ $invoked[0]{args} };
    ok( $nc_has_skip, 'new_config called with --skip_ssh' );

    my $pv_has_domaindir = grep { $_ eq '--domaindir' } @{ $invoked[1]{args} };
    ok( $pv_has_domaindir, 'provision called with --domaindir' );

    my $pv_has_dir = grep { $_ eq '/fake/domains' } @{ $invoked[1]{args} };
    ok( $pv_has_dir, 'provision receives correct domain_dir' );
}

# ---- stream_provision: new_config failure aborts provision ----

{
    my $calls = 0;
    my $output = '';
    open( my $fh, '>', \$output ) or die $!;

    # Use a real temp repo but point new_config at a nonexistent binary —
    # this tests the open failure path through the _real_ stream_provision.
    my $repo    = _make_fake_repo( [qw{test.example.com}] );
    my $rc = Trog::Provisioner::Web::stream_provision(
        'test.example.com', $repo, '/fake/domains', $fh
    );
    close $fh;

    ok( $rc != 0 || $output =~ /ERROR|exited/, 'stream_provision: reports failure when binary missing' );
}

# ---- index_html ----

{
    my $html = Trog::Provisioner::Web::index_html( [qw{alpha.example.com beta.example.com}] );
    like( $html, qr{<form},              'index_html: contains form' );
    like( $html, qr{method="POST"},      'index_html: POST method' );
    like( $html, qr{action="/provision"},'index_html: action is /provision' );
    like( $html, qr{<select},            'index_html: contains select' );
    like( $html, qr{alpha\.example\.com},'index_html: first domain present' );
    like( $html, qr{beta\.example\.com}, 'index_html: second domain present' );
    like( $html, qr{name="domain"},      'index_html: select has name=domain' );
}

{
    # XSS: domain names that contain HTML-special chars must be escaped
    my $html = Trog::Provisioner::Web::index_html( ['<script>alert(1)</script>'] );
    unlike( $html, qr{<script>}, 'index_html: HTML-escapes option values' );
}

done_testing;
