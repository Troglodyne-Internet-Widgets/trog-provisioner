package Trog::Provisioner::Config;

use strict;
use warnings;

use Config::Simple ();

# Fields that must be present and non-empty in provision.conf
our @REQUIRED_FIELDS = qw{
    image
    size
    ips
    gateway
    resolvers
    dhcp_devname
    bridge_devname
    contact_email
};

# Default values applied when a field is absent (same as bin/provision)
our %DEFAULTS = (
    admin_user => 'root',
    cpu_mode   => 'host-passthrough',
    memory     => 2048,
    cpus       => 2,
);

# Validators for specific fields: ($value) -> error string, or '' on success
my %_VALIDATORS = (
    image          => \&_check_url,
    size           => \&_check_pos_int,
    memory         => \&_check_pos_int,
    cpus           => \&_check_pos_int,
    ips            => \&_check_ip_list,
    gateway        => \&_check_ip,
    resolvers      => \&_check_ip_list,
    dhcp_devname   => \&_check_devname,
    bridge_devname => \&_check_devname,
    contact_email  => \&_check_email,
);

=head1 NAME

Trog::Provisioner::Config - load and validate provision.conf files

=head2 load($cfile)

Load a provision.conf file and validate it.
Returns C<($config, \@errors)> where $config is a L<Config::Simple> object
(may be undef if the file is unreadable) and @errors is a list of human-readable
problem descriptions. An empty @errors means the config is valid.

=cut

sub load {
    my ( $class, $cfile ) = @_;

    unless ( -f $cfile ) {
        return ( undef, ["provision.conf not found: $cfile"] );
    }

    my $cfg = Config::Simple->new($cfile);
    unless ($cfg) {
        return ( undef, ["Could not parse $cfile: $Config::Simple::errstr"] );
    }

    my @errors = $class->validate($cfg);
    return ( $cfg, \@errors );
}

=head2 validate($cfg)

Validate a L<Config::Simple> object against the provisioner schema.
Returns a list of error strings; empty list means valid.

=cut

sub validate {
    my ( $class, $cfg ) = @_;
    my @errors;

    for my $field (@REQUIRED_FIELDS) {
        my $val = $cfg->param($field);
        my $missing = !defined $val
            || ( ref $val eq 'ARRAY' && !@$val )
            || ( !ref $val && $val eq '' );

        if ($missing) {
            push @errors, "Required field '$field' is missing or empty";
            next;
        }

        if ( my $checker = $_VALIDATORS{$field} ) {
            my $err = $checker->($val);
            push @errors, "Field '$field': $err" if $err;
        }
    }

    # Also validate optional fields if the user bothered to set them
    for my $field ( keys %_VALIDATORS ) {
        next if grep { $_ eq $field } @REQUIRED_FIELDS;
        my $val = $cfg->param($field);
        next unless defined $val && $val ne '';
        my $err = $_VALIDATORS{$field}->($val);
        push @errors, "Field '$field': $err" if $err;
    }

    return @errors;
}

=head2 check_domain_files($domain_dir, $domain)

Check that the mandatory per-domain files exist alongside provision.conf.
Returns a list of error strings.

=cut

sub check_domain_files {
    my ( $class, $domain_dir, $domain ) = @_;
    my @errors;
    for my $file (qw{ users.yaml data.tar.gz }) {
        my $path = "$domain_dir/$domain/$file";
        push @errors, "Missing required domain file: $path" unless -f $path;
    }
    return @errors;
}

=head2 check_system_prereqs(\&which_fn)

Verify that system tools required by bin/provision are available.
Accepts an optional C<\&which_fn> override (default: File::Which::which) so
the caller can stub it in tests.  Returns a list of error strings.

=cut

sub check_system_prereqs {
    my ( $class, $which_fn ) = @_;

    $which_fn //= do {
        require File::Which;
        \&File::Which::which;
    };

    my @errors;

    for my $tool (qw{ terraform virsh brctl qemu-system-x86_64 }) {
        push @errors, "System tool not found in PATH: $tool"
            unless $which_fn->($tool);
    }

    # KVM module check (best-effort — only when /proc/modules is available)
    if ( -e '/proc/modules' ) {
        open my $fh, '<', '/proc/modules' or next;
        my $kvm_loaded = grep { /^kvm\b/ } <$fh>;
        close $fh;
        push @errors, "KVM kernel module not loaded — enable in BIOS and run: modprobe kvm"
            unless $kvm_loaded;
    }

    return @errors;
}

# ---- private validators ----

sub _check_url {
    my ($val) = @_;
    return "must be a URL starting with http:// or https://"
        unless $val =~ m{\Ahttps?://\S+\z};
    return '';
}

sub _check_pos_int {
    my ($val) = @_;
    return "must be a positive integer" unless $val =~ m/\A[1-9]\d*\z/;
    return '';
}

sub _check_ip {
    my ($val) = @_;
    my $ip = $val;
    $ip =~ s{/\d+\z}{};    # strip optional CIDR suffix
    $ip =~ s/^\s+|\s+$//g;
    return "must be a valid IPv4 address (got '$val')"
        unless $ip =~ m/\A(\d{1,3}\.){3}\d{1,3}\z/
        && !grep { $_ > 255 } split( /\./, $ip );
    return '';
}

sub _check_ip_list {
    my ($val) = @_;
    my @ips = ref $val eq 'ARRAY' ? @$val : split( /,\s*/, $val );
    for my $ip (@ips) {
        $ip =~ s/^\s+|\s+$//g;
        my $err = _check_ip($ip);
        return "invalid IP '$ip': $err" if $err;
    }
    return '';
}

sub _check_devname {
    my ($val) = @_;
    return "must be a valid network interface name (alphanumeric, hyphens, underscores)"
        unless $val =~ m/\A[\w\-]+\z/;
    return '';
}

sub _check_email {
    my ($val) = @_;
    return "must be a valid email address (user\@host)"
        unless $val =~ m/\A[^@\s]+\@[^@\s]+\.[^@\s]+\z/;
    return '';
}

1;
