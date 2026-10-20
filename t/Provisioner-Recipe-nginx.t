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

# What enrich makes of %extra, for the domain web.test.test.
sub enriched {
    my (%extra) = @_;

    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => tempdir( CLEANUP => 1 ),
        distro        => 'ubuntu',
    );
    return { $recipe->enrich( $recipe->validate( domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %extra ) ) };
}

my %VPN = ( ip_pool => { cidr => '10.0.0.0/24', bins => { vpnclients => { cidr => '10.8.0.192/26', via => 'vpn.test.test' }, other => { cidr => '10.9.0.0/24' } } } );

subtest 'a public name in the zone of the domain is served, and one outside it is served as public.VHOST' => sub {
    my $nginx = 'Provisioner::Recipe::nginx';
    is_deeply(
        [ $nginx->served_names( domain => 'web.test.test', public_names => { 'web.test.test' => 'web.test.test', 'shop.web.test.test' => 'web.test.test' } ) ],
        [qw{shop.web.test.test web.test.test}],
        'the domain and a name below it are published and certified as they are'
    );
    is_deeply(
        [
            $nginx->served_names(
                domain       => 'web.test.test',
                public_names => { 'www.customer.test' => 'web.test.test', 'xweb.test.test' => 'web.test.test', 'mail.customer.test' => 'webmail.web.test.test', 'webmail.customer.test' => 'webmail.web.test.test' }
            )
        ],
        [qw{public.web.test.test public.webmail.web.test.test}],
        'a name of another zone, even one that ends in the same letters, is replaced by public.VHOST once for each vhost'
    );
    is_deeply(
        [ $nginx->served_names( domain => 'web.test.test', aliases => { 'web.test.test' => ['alias.test.test'] }, public_names => { 'a.customer.test' => 'www.web.test.test', 'b.customer.test' => 'alias.test.test' } ) ],
        ['public.web.test.test'],
        'www and an alias name the vhost of the domain'
    );
    is_deeply( [ $nginx->served_names( domain => 'web.test.test' ) ], [], 'without public names, nginx serves no name of its own' );
};

subtest 'each vhost that a public name names answers for it on the ports of the proxy' => sub {
    my $opts = enriched(
        %VPN,
        sites        => [qw{web.test.test webmail.web.test.test}],
        public_names => { 'shop.web.test.test' => 'web.test.test', 'webmail.customer.test' => 'webmail.web.test.test', 'webmail.web.test.test' => 'webmail.web.test.test' }
    );
    is_deeply(
        $opts->{proxied},
        { 'web.test.test' => ['shop.web.test.test'], 'webmail.web.test.test' => [qw{public.webmail.web.test.test webmail.customer.test}] },
        'each vhost gets its public names, public.VHOST for a name outside the zone, and not its own name'
    );
    is_deeply( $opts->{domain_names}, ['web.test.test'], 'and the vhost of the domain does not also list them, so no name is in two server blocks' );

    $opts = enriched(
        %VPN,
        aliases      => { 'web.test.test' => ['old.web.test.test'] },
        sites        => [qw{web.test.test www.web.test.test}],
        public_names => { 'www.web.test.test' => 'web.test.test', 'old.web.test.test' => 'web.test.test' }
    );
    is_deeply( $opts->{proxied},      { 'web.test.test' => [] },             'www and an alias are public as names that the vhost of the domain has already' );
    is_deeply( $opts->{domain_names}, [qw{web.test.test old.web.test.test}], 'and it keeps the alias' );
    is_deeply( $opts->{proxy_from},   ['10.8.0.192/26'],                     'nginx believes a PROXY header from the bin that routes through the VPN, and from no other bin' );

    is_deeply(
        enriched( %VPN, sites => ['web.test.test'], public_names => { 'web.test.test' => 'web.test.test' }, proxy_from => ['192.0.2.1/32'] )->{proxy_from},
        ['192.0.2.1/32'], 'proxy_from, when it is set, is the whole list'
    );
    is( enriched( sites => ['web.test.test'] )->{proxied}, undef, 'and without public names no vhost listens for a proxy' );
};

subtest 'a public name that no vhost of the guest can answer for stops the build' => sub {
    my %webmail = ( %VPN, sites => ['webmail.web.test.test'] );

    # The start of a refusal that names each of @names, in that order.
    my $naming = sub (@names) { my $list = join( ', ', @names ); return qr/points[ ]\Q$list\E[ ]at[ ]\S+,[ ]but[ ]/ };
    like(
        exception { enriched( %webmail, public_names => { 'web.test.test' => 'web.test.test', 'shop.web.test.test' => 'web.test.test' } ) },
        qr/${\ $naming->(qw{shop.web.test.test web.test.test})}no[ ]recipe/,
        'no vhost serves the vhost that they name, and the message names each of them'
    );
    is( exception { enriched( %webmail, public_names => { 'webmail.customer.test' => 'webmail.web.test.test' } ) }, undef, 'but a vhost that serves another name can answer for it' );
    like(
        exception {
            enriched(
                %VPN,
                sites        => [qw{web.test.test mail.web.test.test pop.web.test.test}],
                public_names => { 'mail.web.test.test' => 'web.test.test', 'pop.web.test.test' => 'web.test.test', 'shop.web.test.test' => 'web.test.test' }
            )
        },
        qr/${\ $naming->(qw{mail.web.test.test pop.web.test.test})}each[ ]is[ ]a[ ]name[ ]that[ ]another/,
        'another vhost lists the names, and the message names each of them and not the free one'
    );
    like(
        exception { enriched( %VPN, sites => ['other.test'], public_names => { 'shop.other.test' => 'other.test', 'www.other.test' => 'other.test' } ) },
        qr/${\ $naming->(qw{shop.other.test www.other.test})}\S+[ ]is[ ]outside/,
        'the vhost is outside the zone of the domain, and the message names each of them'
    );
    like( exception { enriched( ip_pool => { cidr => '10.0.0.0/24' }, sites => ['web.test.test'], public_names => { 'web.test.test' => 'web.test.test' } ) }, qr/where[ ]the[ ]proxy[ ]connects/, 'no network to believe the header from' );
};

subtest 'the ports of the proxy get the limits of the ports that it fronts' => sub {
    my %limits = 'Provisioner::Recipe::nginx'->rate_limits( public_names => { 'web.test.test' => 'web.test.test' } );
    is_deeply( [ sort { $a <=> $b } keys %limits ], [ 80, 443, 8080, 8443 ], 'with public names' );
    is( $limits{8443}, $limits{443}, 'at the same limit' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
