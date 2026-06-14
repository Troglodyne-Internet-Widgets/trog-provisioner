#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Path qw{make_path};
use File::Slurper qw{write_text read_text};
use JSON::PP ();

use FindBin;

# Net::OpenSSH::More may not be installed in CI/dev environments.
# Stub it so bin/provision compiles; we only test pure functions here.
BEGIN {
    $INC{'Net/OpenSSH/More.pm'} = 1;
    package Net::OpenSSH::More;
    sub new  { bless {}, shift }
    sub cmd  { () }
    sub sftp { bless {}, 'Net::OpenSSH::More::SFTP' }
    sub cmd_exit_code { 0 }

    package Net::OpenSSH::More::SFTP;
    sub put { 1 }
}

require "$FindBin::Bin/../bin/provision";

# Minimal Config::Simple stand-in for unit tests
package MockConfig;
sub new {
    my ($class, %params) = @_;
    bless { params => \%params }, $class;
}
sub param {
    my ($self, $key, $val) = @_;
    $self->{params}{$key} = $val if @_ > 2;
    return $self->{params}{$key};
}

package main;

# --- _coerce_array ---

subtest '_coerce_array: scalar becomes single-element arrayref' => sub {
    my $r = Trog::Bin::Provisioner::_coerce_array('one');
    is(ref $r, 'ARRAY', 'returns arrayref');
    is_deeply($r, ['one'], 'contains single value');
};

subtest '_coerce_array: multiple args become arrayref' => sub {
    my $r = Trog::Bin::Provisioner::_coerce_array('a', 'b', 'c');
    is_deeply($r, [qw{a b c}], 'preserves order');
};

subtest '_coerce_array: no args returns empty arrayref' => sub {
    my $r = Trog::Bin::Provisioner::_coerce_array();
    is_deeply($r, [], 'empty list');
};

# --- inject_admin_key ---

subtest 'inject_admin_key: adds key to matching user' => sub {
    my $userdefs = {
        users => [
            { name => 'admin', ssh_authorized_keys => [] },
            { name => 'other' },
        ],
    };
    Trog::Bin::Provisioner::inject_admin_key('admin', 'test.example', $userdefs, 'ssh-rsa AAAA testkey');
    like($userdefs->{users}[0]{ssh_authorized_keys}[0], qr/testkey/, 'key injected for admin user');
    ok(!exists $userdefs->{users}[1]{ssh_authorized_keys}, 'other user untouched');
};

subtest 'inject_admin_key: creates ssh_authorized_keys if absent' => sub {
    my $userdefs = { users => [{ name => 'admin' }] };
    Trog::Bin::Provisioner::inject_admin_key('admin', 'test.example', $userdefs, 'ssh-rsa BBBB newkey');
    ok(exists $userdefs->{users}[0]{ssh_authorized_keys}, 'key list created');
    like($userdefs->{users}[0]{ssh_authorized_keys}[0], qr/newkey/, 'key present');
};

subtest 'inject_admin_key: no-op when admin_user is undef' => sub {
    my $userdefs = { users => [{ name => 'admin' }] };
    Trog::Bin::Provisioner::inject_admin_key(undef, 'test.example', $userdefs, 'ssh-rsa CCCC key');
    ok(!exists $userdefs->{users}[0]{ssh_authorized_keys}, 'nothing injected when user undef');
};

subtest 'inject_admin_key: no-op when users not an arrayref' => sub {
    my $userdefs = { users => 'not-an-array' };
    eval { Trog::Bin::Provisioner::inject_admin_key('admin', 'test.example', $userdefs, 'ssh-rsa key') };
    is($@, '', 'no exception when users is scalar');
};

subtest 'inject_admin_key: no-op when user not found' => sub {
    my $userdefs = { users => [{ name => 'other' }] };
    Trog::Bin::Provisioner::inject_admin_key('admin', 'test.example', $userdefs, 'ssh-rsa key');
    ok(!exists $userdefs->{users}[0]{ssh_authorized_keys}, 'unmatched user untouched');
};

# --- get_tf_managed_domains ---

sub _make_tfstate {
    my (@domain_names) = @_;
    my @resources = map {
        { type => 'libvirt_domain', name => $_, instances => [] }
    } @domain_names;
    # Add a non-domain resource to verify filtering
    push @resources, { type => 'libvirt_pool', name => 'tf_disks', instances => [] };
    return JSON::PP->new->utf8->encode({ version => 4, resources => \@resources });
}

subtest 'get_tf_managed_domains: returns domain names from tfstate' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sf = "$tmpdir/terraform.tfstate";
    write_text($sf, _make_tfstate('foo-example', 'bar-example'));

    my $domains = Trog::Bin::Provisioner::get_tf_managed_domains($sf);
    is(ref $domains, 'ARRAY', 'returns arrayref');
    is(scalar @$domains, 2, 'two domains found');
    ok((grep { $_ eq 'foo-example' } @$domains), 'foo-example present');
    ok((grep { $_ eq 'bar-example' } @$domains), 'bar-example present');
};

subtest 'get_tf_managed_domains: non-domain resources excluded' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sf = "$tmpdir/terraform.tfstate";
    write_text($sf, _make_tfstate('only-domain'));

    my $domains = Trog::Bin::Provisioner::get_tf_managed_domains($sf);
    ok(!(grep { $_ eq 'tf_disks' } @$domains), 'pool resource excluded');
};

subtest 'get_tf_managed_domains: empty state returns empty list' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sf = "$tmpdir/terraform.tfstate";
    write_text($sf, JSON::PP->new->encode({ version => 4, resources => [] }));

    my $domains = Trog::Bin::Provisioner::get_tf_managed_domains($sf);
    is_deeply($domains, [], 'empty list for empty state');
};

# --- brainwash_tfstate ---

sub _make_tfstate_with_devices {
    my (%opts) = @_;
    my @resources;
    for my $mongled (keys %opts) {
        push @resources, {
            type => 'libvirt_domain',
            name => $mongled,
            instances => [{
                attributes => {
                    devices => {
                        consoles => [
                            {
                                target => { type => 'serial' },
                                source => { pty => '/dev/pts/OLD' },
                            }
                        ],
                        graphics => [],
                    }
                }
            }]
        };
    }
    return JSON::PP->new->utf8->encode({ version => 4, resources => \@resources });
}

subtest 'brainwash_tfstate: updates console pty paths' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sf = "$tmpdir/terraform.tfstate";
    write_text($sf, _make_tfstate_with_devices('my-domain' => { serial => '/dev/pts/NEW' }));

    Trog::Bin::Provisioner::brainwash_tfstate($sf, 'my-domain' => { serial => '/dev/pts/NEW' });

    ok(-f "$sf.bak", 'backup created');
    my $raw = read_text($sf);
    my $parsed = JSON::PP->new->decode($raw);
    my $console = $parsed->{resources}[0]{instances}[0]{attributes}{devices}{consoles}[0];
    is($console->{source}{pty}, '/dev/pts/NEW', 'pty updated');
};

subtest 'brainwash_tfstate: preserves unrelated resources' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $sf = "$tmpdir/terraform.tfstate";
    # State with one domain and one pool resource
    write_text($sf, JSON::PP->new->encode({
        version => 4,
        resources => [
            {
                type => 'libvirt_pool', name => 'tf_disks',
                instances => [{ attributes => { name => 'tf_disks' } }],
            },
            {
                type => 'libvirt_domain', name => 'my-domain',
                instances => [{
                    attributes => {
                        devices => { consoles => [], graphics => [] }
                    }
                }],
            },
        ],
    }));
    Trog::Bin::Provisioner::brainwash_tfstate($sf, 'my-domain' => {});
    ok(-f "$sf.bak", 'backup file exists');
    my $parsed = JSON::PP->new->decode(read_text($sf));
    my @types = map { $_->{type} } @{$parsed->{resources}};
    ok((grep { $_ eq 'libvirt_pool' } @types), 'pool resource still present after brainwash');
};

# --- mongle_setup_script ---

subtest 'mongle_setup_script: substitutes all template placeholders' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    make_path("$tmpdir/test-domain");

    my $config = MockConfig->new(
        domain          => 'test-domain',
        domain_dir      => $tmpdir,
        hv_internal_ip  => '192.168.122.1',
        hv_ssh_port     => '22',
        pre_make_script => '',
    );

    # Temporarily override $domain_dir in the provisioner
    no warnings 'once';
    local $Trog::Bin::Provisioner::domain_dir = $tmpdir;

    my $outfile = Trog::Bin::Provisioner::mongle_setup_script($config);

    ok(-f $outfile, "setup script written to $outfile");
    my $content = read_text($outfile);
    unlike($content, qr/%THISIP%/,  'THISIP replaced');
    unlike($content, qr/%PORT%/,    'PORT replaced');
    unlike($content, qr/%DOMAIN%/,  'DOMAIN replaced');
    unlike($content, qr/%THISDIR%/, 'THISDIR replaced');
    unlike($content, qr/%USER%/,    'USER replaced');
    like($content,   qr/192\.168\.122\.1/, 'HV IP present in output');
};

done_testing;
