#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';

use re '/aa';

=head1 NAME

t/Provisioner-Recipe-fetchcache.t - the fetch cache: which hosts it answers to,
how long it keeps what, and the certificate it answers with

=cut

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use File::Slurper();
use IO::Socket::SSL::Utils();
use Net::SSLeay();

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: the authority is made
# there, and what these assert on should not depend on the machine.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir( CLEANUP => 1 ) }

use Provisioner::Cookbook();
use Provisioner::Recipe::fetchcache();

my $DOMAIN = 'fetchcache.test.test';

# The class, held in a variable: named in full, its lowercase last part reads to
# perlcritic as a function.
my $FETCHCACHE = 'Provisioner::Recipe::fetchcache';

sub generated {
    my (%extra) = @_;

    my $dir    = tempdir( CLEANUP => 1 );
    my $recipe = Provisioner::Cookbook->load( 'fetchcache', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $dir,
        distro        => 'ubuntu',
    );

    my %vars = (
        domain       => $DOMAIN,
        main_ip      => '192.168.1.9',
        full_aliases => ["www.$DOMAIN"],
        install_dir  => '/opt/domains',
        script_dir   => '/root/bin',
        resolvers    => [ '192.168.1.253', '8.8.8.8' ],
        %extra,
    );

    my @written = $recipe->generate_files( $dir, %vars );
    return ( File::Slurper::read_text("$dir/fetchcache.nginx.conf"), $recipe, $dir, \@written );
}

# The hosts it answers to, out of its server_name.
sub allowed {
    my ($vhost) = @_;
    my ($names) = $vhost =~ m/^\s+server_name ([^;]+);$/m;
    return [ sort split( q{ }, $names // q{} ) ];
}

# What one of a certificate's extensions says, as openssl prints it.
sub extension {
    my ( $cert, $name ) = @_;
    my ($ext) = grep { $_->{sn} eq $name } @{ IO::Socket::SSL::Utils::CERT_asHash($cert)->{ext} // [] };
    return $ext ? $ext->{data} : 'none';
}

# A regex alternation of host names, as the vhost writes one, back into names.
sub alternatives {
    my ($re) = @_;
    return [ sort map { s/\\//gr } split( /(?<!\\)[|]/, $re // q{} ) ];
}

subtest 'the upstreams: every host a recipe downloads from, and whatever an operator adds' => sub {
    my ($defaults) = generated();
    my @declared = Provisioner::Cookbook->fetch_hosts;
    is_deeply( allowed($defaults), \@declared, 'every host any recipe names in fetch_hosts, by default' );

    # The default is on each host rather than on the map, so an operator adding
    # one does not replace the lot -- the ufw rate_limits trap.
    my ($added) = generated( upstreams => { 'nodejs.org' => 1 } );
    is_deeply( allowed($added), [ sort( @declared, 'nodejs.org' ) ], 'naming another adds it to them' );

    my ($removed) = generated( upstreams => { 'github.com' => 0 } );
    is_deeply( allowed($removed), [ grep { $_ ne 'github.com' } @declared ], 'and naming one false takes it away' );

    # On most guests this is the only server on 443, and so the default one for
    # any name at all.
    my ($guard) = $defaults =~ m/^map \$host \$fetchcache_allowed \{\n\s+"~\^\(\?:(.*?)\)\$" 1;$/m;
    is_deeply( alternatives($guard), \@declared, 'a request for any other host is told apart' );
    like( $defaults, qr/if \(\$fetchcache_allowed = 0\) \{\n\s+return 421;/, 'and refused' );
};

subtest 'what the vhost will not accept' => sub {

    # They are written into it as a regex, and into a certificate.
    like( exception { generated( upstreams => { 'evil.test/x|.*' => 1 } ) }, qr/plain host names/, 'a host that is not a plain DNS name' );

    my %none = map { $_ => 0 } @{ allowed( ( generated() )[0] ) };
    like( exception { generated( upstreams => \%none ) }, qr/no upstreams turned on/, 'no hosts at all, which would fetch nothing' );

    like( exception { generated( resolvers => [] ) }, qr/needs resolvers/, 'and no resolvers to look them up with' );

    like( exception { generated( resolvers => [ '127.0.0.1', '::1' ] ) }, qr/needs resolvers/, 'or none it can reach' );
};

subtest 'each kind of URL gets its own freshness, and its own redirect handling' => sub {
    my ($vhost) = generated( fresh_index => '5m', fresh_immutable => '30d', fresh_default => '2h' );

    foreach my $class ( [ index => '5m' ], [ immutable => '30d' ], [ default => '2h' ] ) {
        my ( $name, $fresh ) = @$class;

        # The location for the kind, then its @follow, each keeping only a 200
        # for as long as that kind is fresh.
        like(
            $vhost,
            qr{location = /\.fetchcache/$name \{\n\s+internal;\n\s+proxy_cache_valid 200 \Q$fresh\E;\n\s+error_page 301 302 303 307 308 = \@follow_$name;\n\s+proxy_pass https://\$host\$request_uri;},
            "$name: fresh for $fresh, fetched as the guest asked for it, redirects followed"
        );
        like( $vhost, qr/location \@follow_$name \{.*?proxy_cache_valid 200 \Q$fresh\E;.*?proxy_pass \$fetchcache_location;/s, "$name: and a followed redirect is kept as long" );
    }

    # nginx takes the first regex in a map that matches.
    my ($map) = $vhost =~ m/^map "\$host\$request_uri" \$fetchcache_class \{\n(.*?)^\}/ms;
    my @order = ( $map // q{} ) =~ m/^\s+"~[^\n]*" (\w+);$/mg;
    is_deeply( \@order, [qw{pass index immutable}], 'what is never kept first, then the most specific first' );
    like( $map // q{}, qr/^\s+default default;$/m, 'and anything else is the default kind' );

    like( $vhost, qr{location / \{.*?rewrite \^ /\.fetchcache/\$fetchcache_class last;}s, 'every request goes out through the location for its kind' );
};

subtest 'what is never kept goes upstream as it came' => sub {
    my ($vhost) = generated();

    like( $vhost, qr{if \(\$request_method !~ "\^\(\?:GET\|HEAD\)\$"\) \{\n\s+rewrite \^ /\.fetchcache/pass last;}, 'nothing but GET and HEAD is kept' );

    my ($pass) = $vhost =~ m{(location = /\.fetchcache/pass \{.*?\n    \})}s;
    ok( defined $pass, 'and what is not has a location of its own' ) or return;

    like( $pass, qr/^\s+internal;$/m,                     'one nobody can ask for by name' );
    like( $pass, qr/^\s+proxy_cache off;$/m,              'where nothing is kept' );
    like( $pass, qr/^\s+proxy_set_header Host \$host;$/m, 'which goes to the host it was for' );
    unlike( $pass, qr/proxy_set_header (?:Authorization|Cookie)/, 'with whatever credentials it came with' );
    like( $pass, qr/^\s+proxy_intercept_errors off;$/m,  'and hands back its redirects rather than following them' );
    like( $pass, qr/^\s+proxy_request_buffering off;$/m, 'streaming what it is sent, a git push included' );
};

subtest 'a followed redirect is kept under the URL the guest asked for, and goes nowhere else' => sub {
    my ($vhost) = generated();

    like( $vhost, qr/^\s+proxy_cache_key \$host\$request_uri;$/m, 'the key is the host and the request, which no rewrite or internal redirect changes' );
    like( $vhost, qr/^\s+recursive_error_pages on;$/m,            'a second hop is followed too' );

    my @guards = $vhost =~ m/if \(\$fetchcache_location ~ "\^https:\/\/\(\(\?:([^)]*)\)\)\/"\) \{\n\s+set \$fetchcache_next \$1;\n\s+\}\n\s+if \(\$fetchcache_next = ""\) \{\n\s+return 502;/g;
    ok( scalar @guards, 'a redirect is checked before it is followed' ) or return;
    is_deeply( alternatives($_), allowed($vhost), 'against the hosts it answers to, and only over https' ) for @guards;

    # Measured on a guest: cpan.metacpan.org/src/5.0/, which perlbrew lists
    # what perls there are from, redirects to www.cpan.org, which adds the
    # slash back with an http:// Location -- and refusing that was a 502, and
    # a guest with no perl.
    like( $vhost, qr/if \(\$fetchcache_location ~ "\^http:\/\/\(\.\*\)\$"\) \{\n\s+set \$fetchcache_location "https:\/\/\$1";/,                  'a redirect to plain http is followed over https' );
    like( $vhost, qr/^\s+set \$fetchcache_via \$host;$/m,                                                                                        'a redirect naming no host is on the host asked for' );
    like( $vhost, qr/if \(\$fetchcache_location ~ "\^\/"\) \{\n\s+set \$fetchcache_location "https:\/\/\$fetchcache_via\$fetchcache_location";/, 'and made whole against it before it is checked' );
    like( $vhost, qr/if \(\$fetchcache_location ~ "\^\/\/"\) \{\n\s+set \$fetchcache_location "https:\$fetchcache_location";/,                   'one naming no scheme is https' );
    like( $vhost, qr/^\s+set \$fetchcache_via \$fetchcache_next;$/m,                                                                             'and after a hop, a relative one is on the host that hop went to' );
};

subtest 'upstream is trusted as little as possible' => sub {
    my ($vhost) = generated();

    like( $vhost, qr/^\s+proxy_ssl_verify on;$/m,                                 'its certificate is verified' );
    like( $vhost, qr/^\s+proxy_ssl_server_name on;$/m,                            'for the name that was asked for' );
    like( $vhost, qr/^\s+proxy_set_header Authorization "";$/m,                   'no credentials go to it for anything kept' );
    like( $vhost, qr/^\s+proxy_set_header Cookie "";$/m,                          'nor cookies' );
    like( $vhost, qr/^\s+proxy_ignore_headers [^;]*\bCache-Control\b/m,           'and its caching headers do not decide what is kept' );
    like( $vhost, qr/^\s+proxy_cache_use_stale [^;]*\berror\b[^;]*\bhttp_503\b/m, 'what it had is served when upstream fails' );
    like( $vhost, qr/^\s+resolver 192\.168\.1\.253 8\.8\.8\.8 ipv6=off;$/m,       'looked up through the resolvers it was given' );

    # The fleet's list, as a real ipmap.cfg has it: a loopback for guests that
    # run the pdns recursor, which this one does not, and an IPv6 address nginx
    # is told not to use.  Measured on a guest: nginx rotated onto 127.0.0.1
    # and every few lookups was a refused connection.
    my ($fleet) = generated( resolvers => [qw{127.0.0.1 192.168.1.254 8.8.8.8 2600:1700::1}] );
    like( $fleet, qr/^\s+resolver 192\.168\.1\.254 8\.8\.8\.8 ipv6=off;$/m, 'and only the ones it can reach' );

    # github.com sends five kilobytes of headers, which the default buffer turned
    # into a 502 before the redirect in them was read.
    like( $vhost, qr/^\s+proxy_buffer_size 16k;$/m, 'with room for GitHub headers' );
};

subtest 'a copy is removed for want of room, never for its age' => sub {
    my ($vhost) = generated();
    my ($path)  = $vhost =~ m/^(proxy_cache_path [^;]*);$/m;
    ok( defined $path, 'there is a store' ) or return;

    # The copy nobody has asked for in a year is the pinned version upstream may
    # no longer have, so age alone must not take it.
    like( $path, qr/ inactive=100y\b/, 'kept however long since anybody asked for it' );
    like( $path, qr/ max_size=20g\b/,  'until the store is full' );
    like( $path, qr/ min_free=5g\b/,   'or the disk under it nearly is' );

    my ($off) = generated( min_free_gb => 0 );
    unlike( $off, qr/min_free=/, 'and min_free can be turned off' );
};

subtest 'on 443 and 80 under the names of the hosts, so it shares a guest with a package mirror' => sub {
    my ( $vhost, undef, undef, $written ) = generated();

    like( $vhost, qr/^\s+listen 443 ssl;$/m,        'it listens on 443, with TLS' );
    like( $vhost, qr/^\s+listen \[::\]:443 ssl;$/m, 'on IPv6 too' );

    # Measured on a guest: cpanm fetches CPAN over plain http, and pointed here
    # by name it reached another server on 80 and unpacked a 404.
    like( $vhost, qr/^\s+listen 80;$/m,        'and on 80, for what asks over plain http' );
    like( $vhost, qr/^\s+listen \[::\]:80;$/m, 'on IPv6 too' );
    is( scalar( () = $vhost =~ m/^server \{$/mg ), 1, 'with the same locations for both, being one server' );

    unlike( $vhost, qr/default_server|backlog/, 'claiming neither default_server nor the backlog, which whatever else is on those ports may' );
    like( $vhost, qr{^\s+location = /fetchcache-status \{$}m, 'saying it is there, to whatever asks by one of those names' );
    is_deeply( [ sort @$written ], [qw{fetchcache.crt fetchcache.key fetchcache.nginx.conf}], 'the vhost, a certificate, and its key' );

    my ($v4) = generated( ipv6 => 0 );
    unlike( $v4, qr/listen \[::\]/, 'and IPv4 alone when told to' );

    # An aptmirror answers on 80 to the guest name and its address.  nginx
    # routes a port between servers by name, and ignores a second server for a
    # name the first already has -- so what lets the two share a guest is that
    # they share no name, and that only one of them sets the backlog.
    my $mirror = tempdir( CLEANUP => 1 );
    Provisioner::Cookbook->load( 'aptmirror', distro => 'ubuntu' )->new(
        template_dirs => Provisioner::Cookbook->template_dirs('ubuntu'),
        output_dir    => $mirror,
        distro        => 'ubuntu',
    )->generate_files( $mirror, domain => $DOMAIN, main_ip => '192.168.1.9', full_aliases => [], install_dir => '/opt/domains', script_dir => '/root/bin', releases => ['noble'] );
    my $theirs = File::Slurper::read_text("$mirror/aptmirror.nginx.conf");

    my ($their_names) = $theirs =~ m/^\s+server_name ([^;]+);$/m;
    my %ours = map { $_ => 1 } @{ allowed($vhost) };
    is_deeply( [ grep { $ours{$_} } split( q{ }, $their_names // q{} ) ], [], 'it and the mirror answer to no name in common' );
    like( $theirs, qr/listen 80 backlog=/, 'and the backlog on 80 is the mirror\'s alone' );
};

subtest 'the certificate names every host it answers to, and the authority signed it' => sub {
    my ( $vhost, undef, $dir ) = generated( upstreams => { 'nodejs.org' => 1 } );
    my $authority = $FETCHCACHE->authority();

    my @chain = File::Slurper::read_text("$dir/fetchcache.crt") =~ m/(-----BEGIN CERTIFICATE-----\n.*?-----END CERTIFICATE-----\n)/sg;
    is( scalar @chain, 2,                                              'a certificate with one more after it, as nginx wants a chain' );
    is( $chain[1],     File::Slurper::read_text( $authority->{cert} ), 'which is the authority' );

    my $leaf   = IO::Socket::SSL::Utils::PEM_string2cert( $chain[0] );
    my $issuer = IO::Socket::SSL::Utils::PEM_file2cert( $authority->{cert} );
    my $info   = IO::Socket::SSL::Utils::CERT_asHash($leaf);

    is_deeply( [ sort map { $_->[1] } grep { $_->[0] eq 'DNS' } @{ $info->{subjectAltNames} } ], allowed($vhost), 'naming every host it answers to, the one an operator added included' );
    is( Net::SSLeay::X509_verify( $leaf, Net::SSLeay::X509_get_pubkey($issuer) ), 1, 'signed by the authority' );
    is( extension( $leaf, 'basicConstraints' ), 'CA:FALSE',                      'and able to sign nothing itself' );
    is( extension( $leaf, 'extendedKeyUsage' ), 'TLS Web Server Authentication', 'being for a server alone' );

    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers, Plicease::ProhibitLeadingZeros) -- a file mode
    is( ( stat("$dir/fetchcache.key") )[2] & 0777, 0600, 'its key readable by nobody else' );
    ## use critic

    IO::Socket::SSL::Utils::CERT_free($_) for $leaf, $issuer;
};

subtest 'the authority is made once, kept in the configuration directory, and its key kept close' => sub {
    my $first = $FETCHCACHE->authority();
    my $cert  = File::Slurper::read_text( $first->{cert} );

    like( $first->{cert}, qr{\A\Q$ENV{TROG_PROVISIONER_CONFIG}\E/fetchcache-ca\.crt\z}, 'beside the rest of the configuration' );
    is( File::Slurper::read_text( $FETCHCACHE->authority()->{cert} ), $cert, 'asked again, it is the same authority' );

    my $ca = IO::Socket::SSL::Utils::PEM_file2cert( $first->{cert} );
    is( extension( $ca, 'basicConstraints' ), 'CA:TRUE', 'and one that can sign' );
    IO::Socket::SSL::Utils::CERT_free($ca);

    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers, Plicease::ProhibitLeadingZeros) -- a file mode
    is( ( stat( $first->{key} ) )[2] & 0777, 0600, 'with a key readable by nobody else' );
    ## use critic
};

# The patterns are PCRE nginx evaluates; these ones read the same in perl, so what
# each URL is taken for can be asked here rather than on a guest.
subtest 'which kind each URL recipes fetch is taken for' => sub {
    my @CLASSES = $FETCHCACHE->classes();
    my $kind    = sub {
        my ($url) = @_;
        return 'pass' if $url =~ m{^(?:$Provisioner::Recipe::fetchcache::PASSTHROUGH)};
        foreach my $class (@CLASSES) {
            return $class->{name} if !defined $class->{pattern} || $url =~ m{^(?:$class->{pattern})};
        }
        return 'none';
    };

    my $sha = '2082d13bb195f3203d41a308b89417426a7deca1';
    foreach my $case (
        [ 'www.cpan.org/modules/02packages.details.txt.gz'                           => 'index' ],
        [ 'fastapi.metacpan.org/v1/download_url/Sys::Virt'                           => 'index' ],
        [ 'api.github.com/repos/deuxfleurs-org/garage/tags'                          => 'index' ],
        [ 'github.com/o/r/releases/latest/download/x.tgz'                            => 'index' ],
        [ 'www.cpan.org/authors/id/D/DA/DANBERR/Sys-Virt-v10.0.0.tar.gz'             => 'immutable' ],
        [ 'github.com/o/r/releases/download/v1.0/x.tgz'                              => 'immutable' ],
        [ "github.com/o/r/archive/$sha.tar.gz"                                       => 'immutable' ],
        [ 'github.com/o/r/archive/refs/tags/v1.0.tar.gz'                             => 'immutable' ],
        [ "codeload.github.com/prabirshrestha/async.vim/tar.gz/$sha"                 => 'immutable' ],
        [ 'garagehq.deuxfleurs.fr/_releases/v1.0.1/x86_64-unknown-linux-musl/garage' => 'immutable' ],
        [ 'download.imagemagick.org/archive/releases/ImageMagick-7.1.1-47.tar.xz'    => 'immutable' ],

        # These move, and a year of the first copy would be a year of the wrong
        # file.
        [ 'www.cpan.org/authors/id/D/DA/DANBERR/CHECKSUMS'         => 'default' ],
        [ 'github.com/o/r/archive/refs/heads/master.tar.gz'        => 'default' ],
        [ 'codeload.github.com/o/r/tar.gz/refs/heads/master'       => 'default' ],
        [ 'raw.githubusercontent.com/nvm-sh/nvm/master/install.sh' => 'default' ],

        # And this says where each branch is now, so is never kept at all.
        [ 'github.com/Troglodyne-Internet-Widgets/tCMS.git/info/refs?service=git-upload-pack' => 'pass' ],
        [ 'github.com/o/r/info/refs?service=git-receive-pack'                                 => 'pass' ],
    ) {
        my ( $url, $want ) = @$case;
        is( $kind->($url), $want, "$url is $want" );
    }
};

subtest 'the classes are the union of what the recipes declare' => sub {

    # Most specific first, and index before immutable: nginx takes the first
    # map entry that matches, so a release tarball under a releases/latest URL
    # has to meet the index pattern before the immutable one sees it.
    is_deeply(
        [ map { $_->{name} } @Provisioner::Recipe::fetchcache::CLASS_ORDER ],
        [qw{index immutable}],
        'the classes are tried most specific first'
    );

    # The patterns used to live here, which meant a recipe gaining an upstream
    # was a reason to edit the cache.  They belong to the recipes now, so what
    # has to be asserted is that they still reach the vhost: a recipe declaring
    # one that never arrives would silently get the default freshness.
    my %pattern = map { $_->{name} => $_->{pattern} // q{} } $FETCHCACHE->classes();

    foreach my $name ( Provisioner::Cookbook->names ) {
        foreach my $declared ( Provisioner::Cookbook->load($name)->cache_classes ) {
            ok(
                index( $pattern{ $declared->{class} } // q{}, $declared->{pattern} ) >= 0,
                "$name's $declared->{class} pattern reaches the cache"
            );
        }
    }

    my ($vhost) = generated();
    like( $vhost, qr{\Qauthors/id/\E}, 'and the union is what the vhost is written from' );

    # default is the cache's own, and takes whatever the others did not.
    is( $pattern{default}, q{}, 'default matches on nothing, being the fallback' );
};

subtest 'nothing depends on it, and it salvages nothing' => sub {
    my ( undef, $recipe ) = generated();

    is_deeply( [ sort keys %{ { $recipe->required_recipes() } } ], ['nginx'], 'it needs nginx, and nothing else' );

    is_deeply( [ $recipe->remote_files( '/opt/domains', $DOMAIN ) ], [], 'what it keeps is not salvaged off the guest, being re-fetchable' );
    is_deeply( [ $recipe->restores() ],                              [], 'nor put back onto a rebuilt one' );
    is_deeply( [ $recipe->datadirs() ],                              [], 'and it owns nothing under install_dir' );

    foreach my $name ( Provisioner::Cookbook->names() ) {
        my %theirs = eval { Provisioner::Cookbook->load($name)->required_recipes() };
        ok( !exists $theirs{fetchcache}, "$name does not drag a cache host into its dependency graph" );
    }
};

Test::NoWarnings::had_no_warnings();

done_testing;
