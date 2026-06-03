#!/usr/bin/env perl

# PSGI application for the trog-provisioner web UI.
#
# Usage (from ui/ directory):
#   PERL5LIB=/opt/domains/koan.troglodyne.net/perl5/lib/perl5:/path/to/tPSGI/lib \
#       plackup app.psgi --port 8080

use strict;
use warnings;

use Cwd qw{abs_path};
use FindBin ();
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../lib";

use Config::Simple ();
use TPSGI ();

my $ui_dir    = abs_path($FindBin::Bin);
my $conf_file = "$ui_dir/ui.conf";
my $conf      = Config::Simple->new($conf_file) or die "Cannot read $conf_file: $!";

my %options = TPSGI::get_config();

$options{tpsgi_dir}  = $ui_dir;
$options{basedir}    = '.';
$options{routers}    = ['lib/Routes.pm'];
$options{user}       = $conf->param('user')       || getpwuid($>);
$options{http_user}  = $conf->param('http_user')  || $options{user};

our $app = sub {
    my $self = TPSGI->new(%options);
    return $self->app(@_);
};
