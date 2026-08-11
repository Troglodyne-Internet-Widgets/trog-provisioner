package Provisioner::IPPool;

use strict;
use warnings FATAL => 'all';

use List::Util qw{first};
use Net::IP;
use Config::Simple;

=head1 NAME

Provisioner::IPPool - shared IP pool helpers for new_config and list_ip_pool

=head1 SYNOPSIS

    use Provisioner::IPPool;

    # not an interface for general consumption
    my $pool_block = { addresses => [], cidr => [] };
    my $ip_conf = { 0.0.0.0 => 'test.test' };

    my @ips  = Provisioner::IPPool::pool_ips($pool_block);
    my $ip   = Provisioner::IPPool::auto_assign('ipmap.cfg', 'test.test', $pool_block, $ip_conf);

=head2 SUBROUTINES

=head3 pool_ips($cfg_hashref)

Return ordered list of IPs from an ip_pool config block in ipmap.cfg.

=cut

sub pool_ips {
    my ($pool) = @_;
    my (%seen, @ips);

    if (my $addrs = $pool->{addresses}) {
        for my $ip (split /\s+/, $addrs) {
            next unless $ip =~ /\S/;
            push @ips, $ip unless $seen{$ip}++;
        }
    }

    if (my $cidrs = $pool->{cidr}) {
        for my $cidr (split /\s+/, $cidrs) {
            next unless $cidr =~ /\S/;
            my $net = Net::IP->new($cidr)
                or die "Invalid CIDR '$cidr': " . Net::IP::Error() . "\n";
            do {
                my $ip = $net->ip();
                push @ips, $ip unless $seen{$ip}++;
            } while (++$net);
        }
    }

    return @ips;
}

=head3 auto_assign($cfile, $domain, $pool, $ip_conf)

Find the first unassigned pool IP, write it to ipmap.cfg, and return it.

Dies if the pool is unconfigured or exhausted.

=cut

sub auto_assign {
    my ($cfile, $domain, $pool, $ip_conf) = @_;

    my @pool_ips = pool_ips($pool);
    die "No [ip_pool] section or no IPs found in pool: cannot auto-assign IP for $domain\n"
        unless @pool_ips;

    my %assigned;
    for my $d (keys %$ip_conf) {
        my $ip = $ip_conf->{$d};
        $ip =~ s|/\d+$||;
        $assigned{$ip} = $d;
    }

    my ($chosen) = first { !$assigned{$_} } @pool_ips;
    die "IP pool exhausted: no IPs available for $domain\n" unless $chosen;

    my $c = Config::Simple->new($cfile);
    $c->param("ips.$domain", $chosen);
    $c->save($cfile);

    print "Auto-assigned IP $chosen to $domain (written to $cfile)\n";
    return $chosen;
}

1;
