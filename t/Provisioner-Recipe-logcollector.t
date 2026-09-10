#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-logcollector.t - the sink: how it routes without knowing its
senders, and what it deliberately does not do

=cut

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};
use File::Slurper();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();

my $DOMAIN = 'logs.test.test';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'logcollector', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain      => $DOMAIN,
        install_dir => '/opt/domains',
        script_dir  => '/root/bin',
        %extra,
    );

    $recipe->generate_files( $dir, %vars );
    return ( $dir, $recipe, \%vars );
}

sub slurp { my ( $dir, $file ) = @_; return File::Slurper::read_text("$dir/$file") }

subtest 'it routes on the sender, because it cannot know its senders' => sub {
    my ($dir) = generated();
    my $conf = slurp( $dir, 'logcollector.conf' );

    # A collector is built before most of the guests that will ship to it exist,
    # so there is no list to hand it.  One template, evaluated per message, is
    # what lets a new guest start logging here the moment it is built without
    # anything being added anywhere.
    like( $conf, qr/dynaFile="logcollector-perhost"/,                           'one dynamic file rather than a rule per domain' );
    like( $conf, qr{string="/var/log/hosts/%HOSTNAME:::secpath-replace%\.log"}, 'named for whoever sent it' );

    # Not decoration.  HOSTNAME is whatever the sender put in the message, so
    # without this a sender could call itself ../../etc/cron.d/anything and
    # choose where this guest writes.
    like( $conf, qr/secpath-replace/, 'and a sender cannot choose the path' );
};

subtest 'the fleet logs do not also land in this guest own syslog' => sub {
    my ($dir) = generated();
    my $conf = slurp( $dir, 'logcollector.conf' );

    # The stop has to be inside the listener's own ruleset.  An unscoped one
    # would swallow this guest's local logging as well, and a collector that
    # keeps everybody's logs but not its own is a bad trade.
    like( $conf, qr/input\(type="imtcp" port="514" ruleset="logcollector"\)/, 'the input has a ruleset of its own' );
    like( $conf, qr/ruleset\(name="logcollector"\) \{.*\bstop\b.*\}/s,        'which ends in stop' );
};

subtest 'which transports it opens follows what it was asked for' => sub {
    my ($tcp) = generated();
    like( slurp( $tcp, 'logcollector.conf' ), qr/module\(load="imtcp"\)/, 'tcp by default' );
    unlike( slurp( $tcp, 'logcollector.conf' ), qr/imudp/, 'and only tcp' );

    my ($udp) = generated( protocol => 'udp' );
    like( slurp( $udp, 'logcollector.conf' ), qr/module\(load="imudp"\)/, 'udp when asked' );
    unlike( slurp( $udp, 'logcollector.conf' ), qr/imtcp/, 'and only udp' );

    my ($both) = generated( protocol => 'both' );
    like( slurp( $both, 'logcollector.conf' ), qr/imtcp/, 'both means tcp' );
    like( slurp( $both, 'logcollector.conf' ), qr/imudp/, 'and udp' );
};

subtest 'rotation reopens the files it rotated' => sub {
    my ($dir) = generated( retain => 52, rotate => 'daily' );
    my $conf = slurp( $dir, 'logcollector.logrotate' );

    like( $conf, qr/^\s+rotate 52$/m, 'keeping what it was told to keep' );
    like( $conf, qr/^\s+daily$/m,     'on the schedule it was given' );

    # The configuration this replaced had an empty postrotate/endscript pair, so
    # nothing ever told rsyslog to reopen what had been rotated out from under
    # it and it kept writing to the renamed file forever.
    like( $conf, qr{postrotate\s+/usr/lib/rsyslog/rsyslog-rotate\s+endscript}s, 'and signalling rsyslog afterwards' );
};

subtest 'the firewall hole is asked for on the port it actually listens on' => sub {
    my ( undef, $recipe ) = generated();

    my %default = $recipe->rate_limits();
    is_deeply( [ sort keys %default ], ['514'], 'the syslog port by default' );

    # On the configured port, not on 514.  A collector that was moved would
    # otherwise have the limit applied where nothing is listening and none at
    # all where it is.
    my %moved = $recipe->rate_limits( port => 5514 );
    is_deeply( [ sort keys %moved ], ['5514'], 'and on the port it was moved to' );

    my %both = $recipe->rate_limits( port => 514, protocol => 'both' );
    is_deeply( [ sort keys %both ], [ '514', '514/udp' ], 'both transports get a limit, or the unlimited one is the one that gets used' );

    my %required = $recipe->required_recipes();
    is_deeply( [ sort keys %required ], ['ufw'], 'which is what pulls ufw in, rather than naming it' );
};

subtest 'the profile is one ufw will not silently skip' => sub {
    my ($dir) = generated( port => 5514 );
    my $profile = slurp( $dir, 'logcollector_ufw.conf' );

    # ufw refuses a profile whose section name is also a service name in
    # /etc/services -- syslog is 514/udp there -- and says so only as a warning
    # on stderr, so the profile never makes a rule and nothing fails.
    like( $profile, qr/^\[logcollector\]$/m, 'not named syslog' );
    like( $profile, qr{^ports=5514/tcp$}m,   'on the port this guest configured' );
};

subtest 'it salvages nothing, and nothing depends on it' => sub {
    my ( undef, $recipe ) = generated();

    # A collector holds the whole fleet's log history.  Salvage lands in the
    # domain's data directory and from there into data.tar.gz and every backup
    # taken of it, which is the wrong place for it by orders of magnitude.
    is_deeply( [ $recipe->remote_files( '/opt/domains', $DOMAIN ) ], [], 'the logs are not pulled off the guest' );
    is_deeply( [ $recipe->restores() ],                              [], 'nor put back onto a rebuilt one' );
    is_deeply( [ $recipe->datadirs() ],                              [], 'and it owns nothing under install_dir, which the data target walks recursively' );

    # The relationship runs one way and through configuration: a guest names a
    # destination, and the destination never learns who its senders are.
    foreach my $name ( Provisioner::Cookbook->names() ) {
        my $class  = Provisioner::Cookbook->load($name);
        my %theirs = eval { $class->required_recipes() };
        ok( !exists $theirs{logcollector}, "$name does not drag a log sink into its dependency graph" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
