#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use File::Temp qw{tempfile};

use FindBin;
use lib "$FindBin::Bin/../lib";

use Provisioner::IPPool;

sub write_ipmap {
    my ($content) = @_;
    my ($fh, $fname) = tempfile(SUFFIX => '.cfg', UNLINK => 1);
    print $fh $content;
    close $fh;
    return $fname;
}

subtest 'pool_ips: explicit addresses' => sub {
    my @ips = Provisioner::IPPool::pool_ips({ addresses => '10.0.0.1 10.0.0.2 10.0.0.3' });
    is_deeply \@ips, ['10.0.0.1', '10.0.0.2', '10.0.0.3'], 'parses space-separated addresses';
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

    eval { Provisioner::IPPool::auto_assign($cfg, 'overflow', $pool, $ip_conf) };
    like $@, qr/exhausted/i, 'dies with exhausted message';
};

subtest 'auto_assign: dies when no pool configured' => sub {
    my $cfg = write_ipmap(<<'END');
[global]
tld=test.local
[ips]
END

    my $pool    = {};
    my $ip_conf = {};

    eval { Provisioner::IPPool::auto_assign($cfg, 'nopool', $pool, $ip_conf) };
    like $@, qr/ip_pool|pool/i, 'dies with no-pool message';
};

done_testing;
