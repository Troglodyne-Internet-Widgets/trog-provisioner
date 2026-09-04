#!/usr/bin/env perl
use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';
use Test::More;
use Test::Fatal;
use File::Temp qw{tempfile};

use FindBin::libs;

# Never the installation's real /etc/trog-provisioner: what these assert on
# should not depend on which machine they run on, or on what is deployed there.
## no critic (CompileTime) -- setting it at compile time is the point:
## anything that reads it must be loaded after, not before.
BEGIN { require File::Temp; $ENV{TROG_PROVISIONER_CONFIG} = File::Temp::tempdir(CLEANUP => 1) }

use_ok( 'Provisioner::IPPool' );

sub write_ipmap {
    my ($content) = @_;
    my ($fh, $fname) = tempfile(SUFFIX => '.cfg', UNLINK => 1);
    print $fh $content;
    close $fh;
    return $fname;
}

subtest 'pool_ips: explicit addresses' => sub {
    my @ips = Provisioner::IPPool::pool_ips({ addresses => '10.0.0.1 10.0.0.2 10.0.0.3' });
    is_deeply \@ips, [qw{10.0.0.1 10.0.0.2 10.0.0.3}], 'parses space-separated addresses';
};

subtest 'pool_ips: CIDR expansion' => sub {
    my @ips = Provisioner::IPPool::pool_ips({ cidr => '192.168.1.0/30' });
    ok scalar(@ips) >= 2, 'expands CIDR to multiple IPs';
    like $ips[0], qr/^192\.168\.1\./, 'IPs are in correct subnet';
};

subtest 'pool_ips: deduplicates overlap' => sub {
    my @ips = Provisioner::IPPool::pool_ips({
        addresses => '10.0.0.1 10.0.0.2',
        cidr      => '10.0.0.0/31',
    });
    my %seen;
    $seen{$_}++ for @ips;
    ok !(grep { $seen{$_} > 1 } keys %seen), 'no duplicate IPs';
};

subtest 'auto_assign: picks first available' => sub {
    my $cfg = write_ipmap(<<'END');
[global]
tld=test.local
[ips]
existing=192.168.1.10
[ip_pool]
addresses = 192.168.1.10 192.168.1.11 192.168.1.12
END

    my $pool    = { addresses => '192.168.1.10 192.168.1.11 192.168.1.12' };
    my $ip_conf = { existing => '192.168.1.10' };

    my $ip = Provisioner::IPPool::auto_assign($cfg, 'newguest', $pool, $ip_conf);
    is $ip, '192.168.1.11', 'first available IP returned';

    require Config::Simple;
    my $c = Config::Simple->new($cfg);
    is $c->param('ips.newguest'), '192.168.1.11', 'IP persisted in ipmap file';
};

subtest 'auto_assign: CIDR pool' => sub {
    my $cfg = write_ipmap(<<'END');
[global]
tld=test.local
[ips]
[ip_pool]
cidr = 192.168.2.0/30
END

    my $pool    = { cidr => '192.168.2.0/30' };
    my $ip_conf = {};

    my $ip = Provisioner::IPPool::auto_assign($cfg, 'cidrguest', $pool, $ip_conf);
    like $ip, qr/^192\.168\.2\./, 'IP from CIDR range';

    require Config::Simple;
    my $c = Config::Simple->new($cfg);
    is $c->param('ips.cidrguest'), $ip, 'CIDR-assigned IP written to file';
};

subtest 'auto_assign: dies when exhausted' => sub {
    my $cfg = write_ipmap(<<'END');
[global]
tld=test.local
[ips]
a=192.168.1.10
b=192.168.1.11
[ip_pool]
addresses = 192.168.1.10 192.168.1.11
END

    my $pool    = { addresses => '192.168.1.10 192.168.1.11' };
    my $ip_conf = { a => '192.168.1.10', b => '192.168.1.11' };

    my $out = exception { Provisioner::IPPool::auto_assign($cfg, 'overflow', $pool, $ip_conf) };
    like $out, qr/exhausted/i, 'dies with exhausted message';
};

subtest 'auto_assign: dies when no pool configured' => sub {
    my $cfg = write_ipmap(<<'END');
[global]
tld=test.local
[ips]
END

    my $pool    = {};
    my $ip_conf = {};

    my $out = exception { Provisioner::IPPool::auto_assign($cfg, 'nopool', $pool, $ip_conf) };
    like $out, qr/ip_pool|pool/i, 'dies with no-pool message';
};

subtest 'pool_ips leaves the network and broadcast addresses alone' => sub {
    # A guest handed .0 or .63 of a /26 looks provisioned right up until it
    # cannot talk to anything.  This is where staging.troglodyne.net=192.168.1.0
    # came from.
    my @ips = Provisioner::IPPool::pool_ips({ cidr => '192.168.1.0/26' });
    is scalar @ips, 62, 'a /26 offers 62 hosts, not 64';
    is $ips[0],  '192.168.1.1',  'starting after the network address';
    is $ips[-1], '192.168.1.62', 'and stopping before the broadcast';
    ok !(grep { $_ eq '192.168.1.0' }  @ips), 'the network address is not on offer';
    ok !(grep { $_ eq '192.168.1.63' } @ips), 'nor is the broadcast';

    is_deeply [Provisioner::IPPool::pool_ips({ cidr => '10.0.0.0/30' })],
        ['10.0.0.1', '10.0.0.2'], 'a /30 offers its two hosts';

    # RFC 3021: a /31 is a point to point link and both addresses are usable.
    is_deeply [Provisioner::IPPool::pool_ips({ cidr => '10.0.0.4/31' })],
        ['10.0.0.4', '10.0.0.5'], 'a /31 keeps both';

    is_deeply [Provisioner::IPPool::pool_ips({ cidr => '10.0.0.9/32' })],
        ['10.0.0.9'], 'and a /32 is the one host it names';

    # An explicit address list is taken at its word; if you wrote it down, you
    # meant it.
    is_deeply [Provisioner::IPPool::pool_ips({ addresses => '192.168.1.0 192.168.1.5' })],
        ['192.168.1.0', '192.168.1.5'], 'addresses given by hand are not second-guessed';
};

done_testing;
