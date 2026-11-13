#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nvm.t - what the file in ~/.bashrc.d of the user does in a shell

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Path();
use File::Slurper::Temp();
use IPC::Run3();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

# The nvm.sh here stands in for the real one: it defines nvm, and nvm use sets
# NVM_BIN, as the real one does.
subtest 'the shell of the user loads nvm, uses the default node, and finds the global modules' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $r   = Provisioner::Cookbook->load( 'nvm', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );
    is_deeply( [ $r->generate_files( $dir, domain => 'node.test.test' ) ], ['nvm.bashrc'], 'the recipe writes the file that bashrc_d installs' );

    my $home = tempdir( CLEANUP => 1 );
    File::Path::make_path("$home/.nvm");
    File::Slurper::Temp::write_text( "$home/.nvm/nvm.sh", qq{nvm() { [ "\$1 \$2" = 'use default' ] && NVM_BIN="\$NVM_DIR/versions/node/v1/bin"; }\n} );

    local $ENV{HOME} = $home;
    delete local @ENV{qw{NVM_BIN NVM_DIR NODE_PATH}};
    IPC::Run3::run3( [ 'bash', '-c', qq{. '$dir/nvm.bashrc'; echo "\$?:\$NODE_PATH"} ], \undef, \my $out, \my $err );
    is( $out, "0:$home/.nvm/versions/node/v1/lib/node_modules\n", 'NODE_PATH is the node_modules beside the bin of the node in use, and the file returns 0' );
    is( $err, q{},                                                'and it says nothing' );

    File::Path::remove_tree("$home/.nvm");
    IPC::Run3::run3( [ 'bash', '-c', qq{. '$dir/nvm.bashrc'; echo "\$?:\$NODE_PATH"} ], \undef, \$out, \$err );
    is( $out, "0:\n", 'without nvm, the file sets nothing, and still returns 0' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
