#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/bash-completion.t - completions/trog-provisioner.bash completes the domain
of new_config, provision and destroy

=head1 DESCRIPTION

Each case loads the completion in bash, sets the words of a command line as
bash sets them for a tab, and prints what the function offers.

=cut

use Test::More;
use Cwd            qw{abs_path};
use File::Basename qw{dirname};
use File::Path     qw{make_path};
use File::Slurper::Temp();
use File::Temp qw{tempdir};
use IPC::Run3();

use FindBin;

my $root       = abs_path("$FindBin::Bin/..");
my $completion = "$root/completions/trog-provisioner.bash";

my $dir = tempdir( CLEANUP => 1 );
make_path("$dir/recipes.d");
File::Slurper::Temp::write_text( "$dir/recipes.yaml",              "_base: {}\nalpha.test: {}\n" );
File::Slurper::Temp::write_text( "$dir/recipes.d/beta.test.yaml",  "beta.test: {}\n" );
File::Slurper::Temp::write_text( "$dir/recipes.d/bravo.test.yaml", "bravo.test: {}\n" );

my $other = tempdir( CLEANUP => 1 );
File::Slurper::Temp::write_text( "$other/recipes.yaml", "other.test: {}\n" );

# bin/domains runs on the perl of its #! line, so that is the perl of this test.
local $ENV{PATH}                    = dirname($^X) . ":$ENV{PATH}";
local $ENV{TROG_PROVISIONER_CONFIG} = $dir;

# What the completion offers when the cursor is on the last of @words.
my sub offers (@words) {
    my $script = <<~'BASH';
      source "$1"
      shift
      COMP_WORDS=("$@")
      COMP_CWORD=$(($# - 1))
      _trog_provisioner_domains
      printf '%s\n' "${COMPREPLY[@]}"
      BASH
    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run3::run3( [ 'bash', '-c', $script, 'bash', $completion, @words ], \undef, \$out, \$err );
    diag $err if $? || $err ne q{};
    return [ grep { $_ ne q{} } split m/\n/, $out ];
}

is_deeply( offers( "$root/bin/provision", 'b' ),                   [qw{beta.test bravo.test}],            'a prefix gets the domains that start with it' );
is_deeply( offers( "$root/bin/destroy", q{} ),                     [qw{alpha.test beta.test bravo.test}], 'no prefix gets every domain' );
is_deeply( offers( "$root/bin/new_config", 'alpha.test', 'b' ),    [qw{beta.test bravo.test}],            'new_config takes more than one, so the next word gets them as well' );
is_deeply( offers( "$root/bin/provision", qw{--hypervisor hv a} ), ['alpha.test'],                        'an option and its value before the domain do not stop the completion' );
is_deeply( offers( "$root/bin/provision", '-' ),                   [],                                    'an option is not completed as a domain' );

is_deeply(
    offers( "$root/bin/provision", '--recipes', "$other/recipes.yaml", q{} ),
    ['other.test'], 'with --recipes FILE, the domains come from that file'
);
is_deeply(
    offers( "$root/bin/provision", '--recipes', '=', "$other/recipes.yaml", q{} ),
    ['other.test'], 'and from --recipes=FILE, which bash splits at the ='
);
is_deeply(
    [ sort @{ offers( "$root/bin/provision", q{--recipes}, "$dir/recipes." ) } ],
    [ "$dir/recipes.d", "$dir/recipes.yaml" ], 'the value of --recipes completes as a file'
);

my ( $out, $err ) = ( q{}, q{} );
IPC::Run3::run3( [ 'bash', '-c', 'source "$1"; complete -p new_config provision destroy', 'bash', $completion ], \undef, \$out, \$err );
is( $?, 0, 'the function is registered for each command' ) or diag $err;
like( $out, qr/-F[ ]_trog_provisioner_domains[ ]$_$/m, "including $_" ) for qw{new_config provision destroy};

done_testing();
