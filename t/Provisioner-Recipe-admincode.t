#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-admincode.t - which guests smoke the Perl repositories they check out

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

my %COMMON = (
    domain      => 'code.test.test',
    install_dir => '/opt/domains',
    admin_user  => 'someadmin',
    script_dir  => '/root/bin',
    basedir     => 'src',
    repos_from  => [ { api_url => 'https://bogus.test.test/api', token => 'bogus', repos_for => ['bogus'] } ],
);

# A fresh recipe per case: validated() memoises onto the object, so a second
# render through the same one answers with the first one's options.
sub fresh {
    return Provisioner::Cookbook->load( 'admincode', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
}

# The smoke runs cpan_install, which installs into the perl that the perl recipe
# builds.  perllsp does not require that recipe, so a guest can have it alone.
subtest 'the checkouts are smoked only on a guest that builds a perl' => sub {
    my $alone = fresh()->render( %COMMON, modules => [qw{admincode perllsp}] );
    unlike( $alone, qr/smoke_perl_modules/, 'a guest with perllsp and no perl queues no smoke' );

    my $built = fresh()->render( %COMMON, modules => [qw{admincode perl perllsp}] );
    like( $built, qr/smoke_perl_modules/, 'a guest with the perl recipe does' );
};

# The git recipe scans these for their ssh host keys, and a host that serves
# no ssh gives it nothing, so its guest test fails.
subtest 'the host keys it asks git for are those of the host that serves ssh' => sub {
    my %git       = fresh()->required_recipes();
    my $hosts_for = sub {
        my (@urls) = @_;
        my %given  = ( admin_user => 'someadmin', repos_from => [ map { { api_url => $_ } } @urls ] );
        my %asked  = $git{git}->(%given);
        return $asked{accounts}{someadmin}{hosts};
    };

    is_deeply( $hosts_for->('https://api.github.com/'),                                   ['github.com'],                    'GitHub serves ssh from github.com, not from its API host' );
    is_deeply( $hosts_for->('https://git.test.test/api/v1'),                              ['git.test.test'],                 'a forge that serves both from one host is asked about that host' );
    is_deeply( $hosts_for->('https://ghe.test.test/api/v3'),                              ['ghe.test.test'],                 'and so is GitHub Enterprise' );
    is_deeply( $hosts_for->( 'https://api.github.com/', 'https://git.test.test/api/v1' ), [ 'github.com', 'git.test.test' ], 'each api_url for itself' );
};

# The settings file is the claude recipe's, and its target can run after this
# one, so the clones are added once every target is done.
subtest 'the checkouts are working directories of the agent only on a guest that runs claude' => sub {
    my $alone = fresh()->render( %COMMON, modules => [qw{admincode}] );
    unlike( $alone, qr/claude_settings/, 'a guest without claude leaves its settings alone' );

    my $with   = fresh()->render( %COMMON, modules => [qw{admincode claude}] );
    my $queued = 'queue_postrun_task /root/bin/claude_settings add-repos /opt/domains/code.test.test/src /opt/domains/code.test.test/.claude/settings.json';
    ok( index( $with, $queued ) >= 0, 'a guest with it adds the basedir clones to the settings of the agent, after every target' ) or diag $with;
};

# Claude Code loads the skills of a checkout only for --add-dir, so this runs
# the function that the recipe writes, with a claude that prints what it got.
subtest 'claude gets --add-dir for every clone, on a guest that runs claude' => sub {
    my $root = tempdir( CLEANUP => 1 );
    foreach my $repo (qw{one/.git .github/.git}) {
        File::Path::make_path("$root/code.test.test/src/$repo");
    }
    File::Path::make_path( "$root/code.test.test/src/notarepo", "$root/other.test.test/src/two/.git" );

    my $bin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$bin/claude", qq{#!/bin/sh\nprintf '%s\\n' "\$@"\n} );
    chmod 0755, "$bin/claude";

    my @sources;
    foreach my $domain (qw{code.test.test other.test.test}) {
        my $dir     = tempdir( CLEANUP => 1 );
        my @written = fresh()->generate_files( $dir, %COMMON, domain => $domain, install_dir => $root, modules => [qw{admincode claude}] );
        is_deeply( \@written, ['admincode.claude.bash'], "the recipe writes the function for $domain" );
        push( @sources, "$dir/admincode.claude.bash" );
    }

    my $run = sub {
        my (@files) = @_;
        my $script = join( q{}, map { ". '$_'\n" } @files ) . "PATH='$bin':\$PATH claude --resume\n";
        IPC::Run3::run3( [ 'bash', '-c', $script ], \undef, \my $out, \my $err );
        is( $err, q{}, 'and bash says nothing about it' );
        return [ split /\n/, $out ];
    };

    my @one = map { ( '--add-dir', "$root/code.test.test/src/$_" ) } qw{one .github};
    is_deeply( [ sort @{ $run->( $sources[0], $sources[0] ) } ], [ sort @one, q{--resume} ], q{each clone of the basedir, dotted ones too, once each however often .bashrc runs, and the arguments of the caller} ) or diag explain $run->( $sources[0], $sources[0] );
    is_deeply( [ sort @{ $run->(@sources) } ], [ sort @one, '--add-dir', "$root/other.test.test/src/two", '--resume' ], 'and the clones of a second domain on the machine as well as the first' );

    my $alone = tempdir( CLEANUP => 1 );
    is_deeply( [ fresh()->generate_files( $alone, %COMMON, modules => [qw{admincode}] ) ], [], 'a guest without claude gets no function' );
    unlike( fresh()->render( %COMMON, modules => [qw{admincode}] ), qr/bashrc/, 'and its .bashrc is left alone' );
};

# The fragment hands the file that the subtest above runs to bashrc_d, which
# t/bashrc_d.t tests.
subtest 'the admin gets the function in ~/.bashrc.d' => sub {
    my $with = fresh()->render( %COMMON, modules => [qw{admincode claude}] );
    ok( index( $with, "/root/bin/bashrc_d someadmin 50-admincode-code.test.test admincode.claude.bash\n" ) >= 0, 'one file per domain, named for it' ) or diag $with;
};

subtest 'the extra packages install at first boot, with the rest' => sub {
    my @deps = fresh()->deps( extra_pkgs => [qw{tig tmux}] );
    ok( ( grep { $_ eq 'tig' } @deps ) && ( grep { $_ eq 'tmux' } @deps ), 'the extra_pkgs of the operator are deps' );
    ok( ( grep { $_ eq 'git' } fresh()->deps() ),                          'and with none, what the clone needs still is' );
};

# make runs the lines of the token, with a sudo that keeps what repos_for would
# have got and exits as told.
subtest 'the token reaches repos_for on stdin, and is gone afterwards whether repos_for succeeds or fails' => sub {
    my $root = tempdir( CLEANUP => 1 );
    File::Path::make_path("$root/code.test.test/src");

    my $bin = tempdir( CLEANUP => 1 );
    File::Slurper::Temp::write_text( "$bin/sudo", qq{#!/bin/sh\nprintf '%s\\n' "\$@" > '$root/argv'\ncat > '$root/stdin'\nexit "\$FAKE_STATUS"\n} );
    chmod 0755, "$bin/sudo";

    my %repo     = ( api_url => 'https://bogus.test.test/api', token => 'tok-bogus', repos_for => [qw{alice some-org}] );
    my $fragment = fresh()->render( %COMMON, install_dir => $root, repos_from => [ \%repo ], modules => [qw{admincode}] );
    my @lines    = grep { index( $_, '.repos_for.token' ) >= 0 } split /\n/, $fragment;
    File::Slurper::Temp::write_text( "$root/Makefile", "all:\n" . join( q{}, map { "\t$_\n" } @lines ) );

    my $token = "$root/code.test.test/.repos_for.token";
    foreach my $status ( 0, 3 ) {
        unlink "$root/argv", "$root/stdin";
        local $ENV{PATH}        = "$bin:$ENV{PATH}";
        local $ENV{FAKE_STATUS} = $status;
        my $said;
        IPC::Run3::run3( [ qw{make -s -C}, $root ], \undef, \$said, \$said );
        my $made = $?;

        is( !!$made, !!$status, "repos_for exiting $status: make " . ( $status ? 'fails' : 'succeeds' ) ) or diag $said;
        ok( !-e $token, "repos_for exiting $status: the token file is gone" )                             or diag $fragment;

        open( my $fh, '<', "$root/stdin" ) or BAIL_OUT("sudo was never run: $!");
        my $got = do { local $/; <$fh> };
        close($fh) or die "Cannot close what sudo read: $!";
        is( $got, 'tok-bogus', "repos_for exiting $status: repos_for got the token on stdin" );
    }

    open( my $fh, '<', "$root/argv" ) or BAIL_OUT("sudo kept no arguments: $!");
    chomp( my @argv = <$fh> );
    close($fh)                                                                                                                           or die "Cannot close the arguments of sudo: $!";
    is_deeply( [ @argv[ -3 .. -1 ] ], [qw{https://bogus.test.test/api alice some-org}], 'one run of repos_for asks about every entity' ) or diag explain \@argv;
};

Test::NoWarnings::had_no_warnings();

done_testing();
