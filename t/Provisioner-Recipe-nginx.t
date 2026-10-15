#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aasx';

=head1 NAME

t/Provisioner-Recipe-nginx.t - nginx sends its logs to syslog as well as to its
files, unless told not to

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }    ## no critic (Variables::RequireLocalizedPunctuationVars) -- read after BEGIN returns, so it cannot be local to it

use Provisioner::Cookbook();

sub global_conf {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );
    $recipe->generate_files( $dir, domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %extra );

    return File::Slurper::read_text("$dir/nginx.global.conf");
}

subtest 'by default both logs also go to syslog' => sub {
    my $conf = global_conf();

    # logshipper forwards what reaches syslog, and nginx otherwise writes only
    # files.  The tags are what a reader greps for on the collector.
    # nohostname, or journald takes the host name for the program and the tag
    # is lost.
    my $sink = qr{syslog:server=unix:/dev/log,nohostname};
    like( $conf, qr{^access_log[ ]$sink,tag=nginx_access[ ]combined;$}m, 'the access log' );
    like( $conf, qr{^error_log[ ]+$sink,tag=nginx_error[ ]warn;$}m,      'and the error log' );
};

subtest 'an operator can keep them in the files alone' => sub {
    unlike( global_conf( syslog => 0 ), qr/syslog:/, 'nothing is sent to syslog' );
};

# The server_name of each site, as the domain fragment writes it: a map from
# the site to the names in its file.
sub site_names {
    my (%extra) = @_;

    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
    my $fragment = $recipe->render( domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %extra );

    my %names;
    my $printf = qr{^printf[ ]\x27server_name[ ]%s;\\n\x27[ ]}m;
    my $file   = qr{/etc/nginx/names/web\.test\.test/([^/]+)\.conf$}m;
    while ( $fragment =~ m{$printf\x27([^\x27]*)\x27[ ]>[ ]$file}mg ) {
        $names{$2} = [ split ' ', $1 ];
    }
    return \%names;
}

subtest 'each vhost answers for its own names, and the vhost of the domain for the rest' => sub {
    my %sites = (
        nginxproxy => { domain => 1 },
        webmail    => { names  => ['webmail.web.test.test'] },
    );
    is_deeply(
        site_names( sites => \%sites, full_aliases => [qw{www.web.test.test webmail.web.test.test mail.web.test.test}] ),
        {
            nginxproxy => [qw{web.test.test www.web.test.test mail.web.test.test}],
            webmail    => ['webmail.web.test.test'],
        },
        'webmail is the vhost of roundcube alone, and the domain keeps every other alias'
    );
    is_deeply( site_names(), {}, 'a domain that declares no site gets no file' );
    is_deeply(
        site_names( sites => { autodiscover => { names => [qw{autodiscover.web.test.test autodiscover.web.test.test}] } } ),
        { autodiscover => ['autodiscover.web.test.test'] },
        'a site that the resolver handed over twice lists each name once'
    );
};

subtest 'a name that nginx would give to only one vhost stops the build' => sub {
    like(
        exception { site_names( sites => { one => { names => ['x.web.test.test'] }, two => { names => ['x.web.test.test'] } } ) },
        qr/x\.web\.test\.test[ ]is[ ]a[ ]name[ ]of[ ]both/, 'one name in two sites'
    );
    like(
        exception { site_names( sites => { one => { domain => 1 }, two => { domain => 1 } } ) },
        qr/all[ ]serve[ ]web\.test\.test/, 'two sites that each serve the domain'
    );
    like( exception { site_names( sites => { empty => {} } ) }, qr/answers[ ]for[ ]no[ ]name/, 'and a site with no name' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
