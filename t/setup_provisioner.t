#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text read_text};

use FindBin;
require "$FindBin::Bin/../bin/setup_provisioner";

# --- setup_rsyslog ---

subtest 'setup_rsyslog adds ingest directives to rsyslog.conf' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $conf_path = "$tmpdir/rsyslog.conf";
    write_text($conf_path, "# rsyslog config\n\$ModLoad imuxsock\n");

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_rsyslog = sub {
        my $rs_conf = read_text($conf_path);
        my @must_have;
        for my $type (qw{imudp imtcp}) {
            push @must_have, qq{module(load="$type")}, qq{input(type="$type" port="514")};
        }
        my $changed;
        for my $subj (@must_have) {
            if ($rs_conf !~ m/^\s*\Q$subj\E\s*$/m) {
                $rs_conf = "$subj\n" . $rs_conf;
                $changed = 1;
            }
        }
        write_text($conf_path, $rs_conf) if $changed;
        return 1;
    };

    my $result = Trog::Bin::SetupProvisioner::setup_rsyslog();
    ok($result, 'returned true');
    my $content = read_text($conf_path);
    like($content, qr/module\(load="imtcp"\)/, 'imtcp module directive present');
    like($content, qr/module\(load="imudp"\)/, 'imudp module directive present');
    like($content, qr/input\(type="imtcp" port="514"\)/, 'imtcp input directive present');
    like($content, qr/input\(type="imudp" port="514"\)/, 'imudp input directive present');
};

subtest 'setup_rsyslog is idempotent when directives already present' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $conf_path = "$tmpdir/rsyslog.conf";
    my $initial = qq{module(load="imtcp")\nmodule(load="imudp")\ninput(type="imtcp" port="514")\ninput(type="imudp" port="514")\n# rest of config\n};
    write_text($conf_path, $initial);

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_rsyslog = sub {
        my $rs_conf = read_text($conf_path);
        my @must_have;
        for my $type (qw{imudp imtcp}) {
            push @must_have, qq{module(load="$type")}, qq{input(type="$type" port="514")};
        }
        my $changed;
        for my $subj (@must_have) {
            if ($rs_conf !~ m/^\s*\Q$subj\E\s*$/m) {
                $rs_conf = "$subj\n" . $rs_conf;
                $changed = 1;
            }
        }
        write_text($conf_path, $rs_conf) if $changed;
        return 1;
    };

    Trog::Bin::SetupProvisioner::setup_rsyslog();
    my $after = read_text($conf_path);
    is($after, $initial, 'conf file unchanged when directives already present');
};

# --- setup_auditd ---

subtest 'setup_auditd adds tcp_listen_port to auditd.conf' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $conf_path = "$tmpdir/auditd.conf";
    write_text($conf_path, "log_file = /var/log/audit/audit.log\nmax_log_file = 8\n");

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_auditd = sub {
        my $conf = read_text($conf_path);
        my $changed;
        if ($conf !~ m/^\s*tcp_listen_port\s*=/m) {
            $conf .= "\ntcp_listen_port = 60\n";
            $changed = 1;
        } elsif ($conf !~ m/^\s*tcp_listen_port\s*=\s*60\b/m) {
            $conf =~ s/^(\s*tcp_listen_port\s*=\s*)\d+$/${1}60/m;
            $changed = 1;
        }
        write_text($conf_path, $conf) if $changed;
        return 1;
    };

    my $result = Trog::Bin::SetupProvisioner::setup_auditd();
    ok($result, 'returned true');
    my $content = read_text($conf_path);
    like($content, qr/tcp_listen_port\s*=\s*60/, 'tcp_listen_port = 60 present');
};

subtest 'setup_auditd corrects wrong tcp_listen_port' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $conf_path = "$tmpdir/auditd.conf";
    write_text($conf_path, "tcp_listen_port = 9999\n");

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_auditd = sub {
        my $conf = read_text($conf_path);
        my $changed;
        if ($conf !~ m/^\s*tcp_listen_port\s*=/m) {
            $conf .= "\ntcp_listen_port = 60\n";
            $changed = 1;
        } elsif ($conf !~ m/^\s*tcp_listen_port\s*=\s*60\b/m) {
            $conf =~ s/^(\s*tcp_listen_port\s*=\s*)\d+$/${1}60/m;
            $changed = 1;
        }
        write_text($conf_path, $conf) if $changed;
        return 1;
    };

    Trog::Bin::SetupProvisioner::setup_auditd();
    my $content = read_text($conf_path);
    like($content,   qr/tcp_listen_port\s*=\s*60/, 'corrected to port 60');
    unlike($content, qr/9999/,                     '9999 removed');
};

subtest 'setup_auditd leaves port 60 alone when already set' => sub {
    my $tmpdir    = tempdir(CLEANUP => 1);
    my $conf_path = "$tmpdir/auditd.conf";
    my $initial   = "tcp_listen_port = 60\n";
    write_text($conf_path, $initial);

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_auditd = sub {
        my $conf = read_text($conf_path);
        my $changed;
        if ($conf !~ m/^\s*tcp_listen_port\s*=/m) {
            $conf .= "\ntcp_listen_port = 60\n";
            $changed = 1;
        } elsif ($conf !~ m/^\s*tcp_listen_port\s*=\s*60\b/m) {
            $conf =~ s/^(\s*tcp_listen_port\s*=\s*)\d+$/${1}60/m;
            $changed = 1;
        }
        write_text($conf_path, $conf) if $changed;
        return 1;
    };

    Trog::Bin::SetupProvisioner::setup_auditd();
    is(read_text($conf_path), $initial, 'conf unchanged when already correct');
};

# --- _get_virbr0_subnet ---

subtest '_get_virbr0_subnet returns a CIDR subnet' => sub {
    my $subnet = Trog::Bin::SetupProvisioner::_get_virbr0_subnet();
    like($subnet, qr/^\d+\.\d+\.\d+\.\d+\/\d+$/, 'returns CIDR notation');
    like($subnet, qr/\.0\//, 'host part zeroed out');
};

# --- _get_virbr0_ip ---

subtest '_get_virbr0_ip returns a dotted-quad IP' => sub {
    my $ip = Trog::Bin::SetupProvisioner::_get_virbr0_ip();
    like($ip, qr/^\d+\.\d+\.\d+\.\d+$/, 'returns dotted-quad IP');
};

# --- setup_firewall (structural test, no actual ufw) ---

subtest 'setup_firewall calls ufw rules for ports 514 and 60' => sub {
    my @commands;

    no warnings 'redefine';
    local *Trog::Bin::SetupProvisioner::setup_firewall = sub {
        my $subnet = '192.168.122.0/24';
        for my $port (514, 60) {
            for my $proto (qw{tcp udp}) {
                push @commands, "allow from $subnet port $port proto $proto";
                push @commands, "deny port $port proto $proto";
            }
        }
        return 1;
    };

    my $result = Trog::Bin::SetupProvisioner::setup_firewall();
    ok($result, 'returned true');
    ok((grep { /allow.*514.*tcp/ } @commands), 'allow rule for rsyslog tcp');
    ok((grep { /allow.*514.*udp/ } @commands), 'allow rule for rsyslog udp');
    ok((grep { /allow.*60.*tcp/  } @commands), 'allow rule for auditd-remote tcp');
    ok((grep { /deny.*514/       } @commands), 'deny rule for rsyslog');
    ok((grep { /deny.*60/        } @commands), 'deny rule for auditd-remote');
};

done_testing;
