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

# The server_name that the domain fragment writes for the vhost of the domain,
# or undef when it writes none.
sub domain_names {
    my (%extra) = @_;

    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
    my $fragment = $recipe->render( domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %extra );

    my $printf  = qr{^printf[ ]\x27server_name[ ]%s;\\n\x27[ ]}m;
    my $file    = qr{/etc/nginx/names/web\.test\.test\.conf$}m;
    my ($names) = $fragment =~ m{$printf\x27([^\x27]*)\x27[ ]>[ ]$file}m;
    return defined $names ? [ split ' ', $names ] : undef;
}

subtest 'the vhost of the domain answers for every alias that no other vhost lists' => sub {
    is_deeply(
        domain_names( sites => [qw{web.test.test webmail.web.test.test}], aliases => { 'web.test.test' => [qw{www.web.test.test webmail.web.test.test mail.web.test.test}] } ),
        [qw{web.test.test www.web.test.test mail.web.test.test}],
        'webmail is the vhost of roundcube alone, and the domain keeps every other alias that the operator configured'
    );
    is( domain_names( sites => ['webmail.web.test.test'] ), undef, 'a domain that no vhost serves gets no file' );
    is( domain_names(),                                     undef, 'nor does a domain that lists no vhost' );
};

subtest 'a name that nginx would give to only one vhost stops the build' => sub {
    my $invalid = qr/\Anginx:[ ]invalid[ ]configuration:[ ]/m;
    my $refusal = qr/${invalid}multiple[ ]recipes[ ]configured[ ]to[ ]serve[ ]/m;
    like(
        exception { domain_names( sites => [qw{x.web.test.test x.web.test.test}] ) },
        qr/${refusal}x\.web\.test\.test$/m, 'one name that two recipes list'
    );
    like(
        exception { domain_names( sites => [qw{web.test.test web.test.test}] ) },
        qr/${refusal}web\.test\.test$/m, 'and two recipes that each serve the domain'
    );
};

Test::NoWarnings::had_no_warnings();

done_testing;
