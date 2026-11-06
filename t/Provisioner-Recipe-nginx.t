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
use Test::MockModule();
use File::Temp qw{tempdir};
use File::Slurper();
use File::Slurper::Temp();
use IPC::Run3();

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

subtest 'a public name in a zone of the registrar is served as it is, without a stand-in' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( domain_config => sub { return { registrar => { accounts => { customer => { type => 'route53', zones => ['customer.test'] } } } } } );
    $mock->redefine( host_of       => sub { return } );

    my $nginx = 'Provisioner::Recipe::nginx';
    is_deeply(
        [ $nginx->served_names( domain => 'web.test.test', public_names => { 'shop.customer.test' => 'webmail.web.test.test', 'customer.test' => 'webmail.web.test.test' } ) ],
        [qw{customer.test shop.customer.test}],
        'each name of that zone is published and certified, and no public.VHOST joins them'
    );
    is_deeply(
        [ $nginx->served_names( domain => 'web.test.test', public_names => { 'shop.customer.test' => 'webmail.web.test.test', 'other.example.test' => 'webmail.web.test.test' } ) ],
        [qw{shop.customer.test public.webmail.web.test.test}],
        'and a name of no zone that the guest can answer for still gets one'
    );
};

subtest 'a proxy routes every public name, and public.VHOST beside a name outside every zone' => sub {
    my $nginx = 'Provisioner::Recipe::nginx';
    is_deeply(
        [ $nginx->proxied_names( domain => 'web.test.test', public_names => { 'shop.web.test.test' => 'web.test.test', 'www.customer.test' => 'www.web.test.test', 'mail.customer.test' => 'webmail.web.test.test' } ) ],
        [qw{mail.customer.test public.web.test.test public.webmail.web.test.test shop.web.test.test www.customer.test}],
        'each name once, sorted, with the name that DNS-01 cannot certify as well as its stand-in'
    );
    is_deeply( [ $nginx->proxied_names( domain => 'web.test.test' ) ], [], 'and without public names, no name' );
};

subtest 'the ports of the proxy get the limits of the ports that it fronts' => sub {
    my %limits = 'Provisioner::Recipe::nginx'->rate_limits( public_names => { 'web.test.test' => 'web.test.test' } );
    is_deeply( [ sort { $a <=> $b } keys %limits ], [ 80, 443, 8080, 8443 ], 'with public names' );
    is( $limits{8443}, $limits{443}, 'at the same limit' );
};

subtest 'the jails of a domain with a relay ban through it' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { my ($domain) = @_; return $domain eq 'relay.test.test' ? { guests => '192.0.2.5', vpnclients => '10.8.0.197' } : {} } );

    my %public = ( %VPN, sites => ['web.test.test'], public_names => { 'web.test.test' => 'web.test.test' } );
    my $opts   = enriched( %public, relay => 'relay.test.test' );
    is( $opts->{relay_address}, '10.8.0.197', 'the guest reaches the relay at its address in the tunnel' );
    is_deeply( $opts->{relay_jails}, [qw{nginx-botsearch nginx-http-auth}], 'and every jail of nginx bans through it' );

    $opts = enriched( %public, relay => 'relay.test.test', proxied_jails => [qw{roundcube-auth nginx-http-auth}] );
    is_deeply( $opts->{relay_jails}, [qw{nginx-botsearch nginx-http-auth roundcube-auth}], 'so does a jail that another recipe hands over, once each' );

    $opts = enriched(%public);
    ok( !exists $opts->{relay_address}, 'a domain with no relay bans through none' );
};

subtest 'a domain with a relay registers there the names that the proxy routes, at the address of its guest' => sub {
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( host_of       => sub { my ( undef, $domain ) = @_; return $domain eq 'shop.test.test' ? 'web.test.test' : undef } );
    $mock->redefine( alias_map     => sub { return {} } );
    $mock->redefine( domain_config => sub { return {} } );
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( assignments => sub { return { 'web.test.test' => '192.0.2.10', 'shop.test.test' => '192.0.2.99' } } );

    my $nginx  = 'Provisioner::Recipe::nginx';
    my %public = ( public_names => { 'www.customer.test' => 'shop.test.test' } );
    my %files  = $nginx->granted_secrets( 'shop.test.test', %public, relay => 'relay.test.test' );
    is_deeply(
        \%files,
        {
            '/etc/fail2ban/nginxrelay/shop.test.test.key.b64' => {
                issue => { guest => 'relay.test.test', command => '/root/bin/nginxrelay_client register shop.test.test 192.0.2.10:8443 192.0.2.10:8080 public.shop.test.test www.customer.test' },
                owner => 'root:root',
                mode  => '0600',
            },
            '/etc/fail2ban/nginxrelay/shop.test.test.host.b64' => {
                issue => { guest => 'relay.test.test', command => 'base64 -w0 /etc/ssh/ssh_host_ed25519_key.pub' },
                owner => 'root:root',
                mode  => '0644',
            },
        },
        'the relay issues the key of the domain and its own host key, and a domain built onto another guest sends its names to that guest'
    );

    is_deeply( { $nginx->granted_secrets( 'shop.test.test', %public ) },                                        {}, 'a domain with no relay registers nothing' );
    is_deeply( { $nginx->granted_secrets( 'shop.test.test', public_names => {}, relay => 'relay.test.test' ) }, {}, 'and nor does one with no public name' );

    $pool->redefine( assignments => sub { return {} } );
    like( exception { $nginx->granted_secrets( 'shop.test.test', %public, relay => 'relay.test.test' ) }, qr/web[.]test[.]test[ ]has[ ]no[ ]address/, 'a guest that the relay cannot reach stops the build' );
};

subtest 'a media name is fetched by the relay on 8080, and gets a certificate of its own' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { my ($domain) = @_; return $domain eq 'relay.test.test' ? { guests => '192.0.2.5', vpnclients => '10.8.0.197' } : {} } );

    my %media = ( %VPN, sites => ['web.test.test'], relay => 'relay.test.test', media_names => { 'media.web.test.test' => 'web.test.test' } );
    my $opts  = enriched(%media);
    is( $opts->{proxied}, undef, 'a media name does not pass through, so no vhost listens for it on 8443' );
    is_deeply( $opts->{proxied_http}, { 'web.test.test' => ['media.web.test.test'] }, 'but its vhost answers for it on 8080, where the relay fetches' );
    is_deeply( $opts->{domain_names}, ['web.test.test'],                              'and the vhost of the domain does not also list it' );
    is_deeply(
        $opts->{relay_cert},
        {
            certs    => [ { name => 'media.web.test.test', dir => 'media.web.test.test' } ],
            key_b64  => '/etc/ssl/nginxrelay/web.test.test.media.key.b64',
            key      => '/etc/ssl/nginxrelay/web.test.test.media.key',
            deployer => '/etc/dehydrated/deployers/nginxrelay-web.test.test',
        },
        'the guest sends its certificate with the media key that the relay issued'
    );
    my $nginx = 'Provisioner::Recipe::nginx';
    is_deeply( [ $nginx->served_names( %media, domain => 'web.test.test' ) ], ['media.web.test.test'], 'the registrar publishes the media name, and letsencrypt certifies it' );

    my %required = $nginx->required_recipes( %media, domain => 'web.test.test' );
    is_deeply(
        { $required{letsencrypt}->() },
        { certificate_readers => ['nginx'], own_certificates => ['media.web.test.test'], certificate_deployers => ['/etc/dehydrated/deployers/nginxrelay-web.test.test'] },
        'on a certificate of its own, which the deployer sends to the relay'
    );
    my %plain = $nginx->required_recipes( domain => 'web.test.test' );
    is_deeply( { $plain{letsencrypt}->() }, { certificate_readers => ['nginx'] }, 'a domain with no media name asks letsencrypt for nothing else' );

    # What each case changes in %media, and why the build stops.
    my %refused = (
        'a media name with no relay'                 => [ [ relay => undef ],                                                    qr/no[ ]relay/ ],
        'a media name outside every zone'            => [ [ media_names => { 'media.customer.test' => 'web.test.test' } ],       qr/cannot[ ]get[ ]the[ ]certificate/ ],
        'a name that is public and media'            => [ [ public_names => { 'media.web.test.test' => 'web.test.test' } ],      qr/both[ ]a[ ]public[ ]name[ ]and[ ]a[ ]media[ ]name/ ],
        'a media name that a vhost lists'            => [ [ sites => [qw{web.test.test media.web.test.test}] ],                  qr/a[ ]vhost[ ]lists/ ],
        'a media name of a vhost that nothing lists' => [ [ media_names => { 'media.web.test.test' => 'other.web.test.test' } ], qr/no[ ]recipe/ ],
    );
    foreach my $case ( sort keys %refused ) {
        my ( $change, $why ) = @{ $refused{$case} };
        my %opts = ( %media, @$change );
        delete $opts{relay} unless defined $opts{relay};
        like( exception { enriched(%opts) }, $why, "$case stops the build" );
    }

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );
    $recipe->generate_files( $dir, domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %media );
    is( deployed( "$dir/nginx_relay_cert", 'media.web.test.test' ), 'root@10.8.0.197 install media.web.test.test', 'the deployer sends the certificate of the media name to the relay, at its address in the tunnel' );
    is( deployed( "$dir/nginx_relay_cert", 'web.test.test' ),       q{},                                           'and no other' );
    like( File::Slurper::read_text("$dir/nginx.global.conf"), qr/listen[ ]8080[ ]default_server/, 'a guest with media names alone still listens for the relay' );
};

# What the deployer at $script asks the relay for when letsencrypt runs it for
# the certificate in the directory $certdir, by way of an ssh that stands in for
# the real one: its last two arguments, or nothing when it did not run.
sub deployed {
    my ( $script, $certdir, $name ) = @_;
    $name //= $certdir;
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/$certdir" or die "Cannot make $dir/$certdir: $!";
    File::Slurper::Temp::write_text( "$dir/$certdir/$_", "PEM\n" ) foreach qw{privkey.pem fullchain.pem};
    File::Slurper::Temp::write_text( "$dir/ssh",         qq{#!$^X\nmy \$pem = do { local \$/; <STDIN> };\nopen( my \$fh, '>', '$dir/asked' ) or die;\nprint {\$fh} "\$ARGV[-2] \$ARGV[-1]";\n} );
    chmod 0755, "$dir/ssh", $script;
    local $ENV{PATH} = "$dir:$ENV{PATH}";
    IPC::Run3::run3( [ 'bash', $script, $name, "$dir/$certdir/privkey.pem", "$dir/$certdir/fullchain.pem" ], \undef, \my $out, \my $err );
    return "exited $?: $err" if $?;
    return q{} unless -e "$dir/asked";
    my $asked = File::Slurper::read_text("$dir/asked");
    chomp $asked;
    return $asked;
}

subtest 'a cached name is fetched by the relay on 8080, on a certificate that names it alone' => sub {
    my $pool = Test::MockModule->new('Provisioner::IPPool');
    $pool->redefine( holdings => sub { my ($domain) = @_; return $domain eq 'relay.test.test' ? { guests => '192.0.2.5', vpnclients => '10.8.0.197' } : {} } );

    my %cached = (
        %VPN,
        sites        => ['web.test.test'],
        relay        => 'relay.test.test',
        public_names => { 'secure.web.test.test' => 'web.test.test' },
        cached_names => { 'web.test.test'        => 'web.test.test' },
    );
    my $opts = enriched(%cached);
    is_deeply( $opts->{proxied},           { 'web.test.test' => ['secure.web.test.test'] }, 'the secure name still passes through on 8443' );
    is_deeply( $opts->{proxied_http},      { 'web.test.test' => ['secure.web.test.test'] }, 'and the vhost answers on 8080, where the relay fetches the cached name, which it lists already' );
    is_deeply( $opts->{relay_cert}{certs}, [ { name => 'web.test.test', dir => 'own-web.test.test' } ], 'the guest sends the certificate of its own of the cached name' );

    my $nginx    = 'Provisioner::Recipe::nginx';
    my %required = $nginx->required_recipes( %cached, domain => 'web.test.test' );
    is_deeply( { $required{letsencrypt}->() }->{own_certificates}, ['web.test.test'], 'which letsencrypt makes' );
    ok( scalar( $nginx->grants( 'web.test.test', %cached, public_names => {} ) ), 'a cached name alone registers on the relay' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'nginx', distro => 'ubuntu' )->new( template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'), output_dir => $dir, distro => 'ubuntu' );
    $recipe->generate_files( $dir, domain => 'web.test.test', install_dir => '/bogus', script_dir => '/bogus/bin', %cached );
    is( deployed( "$dir/nginx_relay_cert", 'own-web.test.test', 'web.test.test' ), 'root@10.8.0.197 install web.test.test', 'the deployer sends the certificate that names the domain alone, as the domain' );
    is( deployed( "$dir/nginx_relay_cert", 'web.test.test' ), q{}, 'and never the certificate of the domain, which names the secure name too' );

    my %refused = (
        'a cached name with no relay'                 => [ [ relay => undef ],                                                                                                            qr/no[ ]relay/ ],
        'a cached name outside every zone'            => [ [ cached_names => { 'www.customer.test' => 'web.test.test' } ],                                                                qr/cannot[ ]get[ ]the[ ]certificate/ ],
        'a name that is public and cached'            => [ [ public_names => { 'web.test.test' => 'web.test.test' } ],                                                                    qr/both[ ]a[ ]public[ ]name[ ]and[ ]a[ ]cached[ ]name/ ],
        'a name that is media and cached'             => [ [ media_names => { 'media.web.test.test' => 'web.test.test' }, cached_names => { 'media.web.test.test' => 'web.test.test' } ], qr/both[ ]a[ ]media[ ]name[ ]and[ ]a[ ]cached[ ]name/ ],
        'a cached name of a vhost that nothing lists' => [ [ cached_names => { 'shop.web.test.test' => 'other.web.test.test' } ],                                                         qr/no[ ]recipe/ ],
        'a cached name that another vhost lists'      => [ [ sites => [qw{web.test.test shop.web.test.test}], cached_names => { 'shop.web.test.test' => 'web.test.test' } ],              qr/another[ ]vhost[ ]lists/ ],
    );
    foreach my $case ( sort keys %refused ) {
        my ( $change, $why ) = @{ $refused{$case} };
        my %opts = ( %cached, @$change );
        delete $opts{relay} unless defined $opts{relay};
        like( exception { enriched(%opts) }, $why, "$case stops the build" );
    }
};

subtest 'the teardown releases the names on the relay whenever the domain names one' => sub {
    my %config;
    my $mock = Test::MockModule->new('Provisioner::Cookbook');
    $mock->redefine( domain_config => sub { return {%config} } );
    my $nginx = 'Provisioner::Recipe::nginx';

    # roundcube adds its public name while the build resolves dependencies,
    # and the teardown reads only what the operator wrote.
    %config = ( nginx => { relay => 'relay.test.test' } );
    my @revocations = $nginx->revocations('web.test.test');
    is( scalar @revocations,      1,                                                   'a relay with no public name written' );
    is( $revocations[0]{guest},   'relay.test.test',                                   'is told on the relay' );
    is( $revocations[0]{command}, '/root/bin/nginxrelay_client release web.test.test', 'to release the names of the domain' );

    %config = ( nginx => { public_names => { 'web.test.test' => 'web.test.test' } } );
    is_deeply( [ $nginx->revocations('web.test.test') ], [], 'a domain with no relay releases nothing' );
};

Test::NoWarnings::had_no_warnings();

done_testing;
