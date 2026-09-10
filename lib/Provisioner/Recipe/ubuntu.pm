package Provisioner::Recipe::ubuntu;

#ABSTRACT: Ubuntu: the image, the packager, and how a guest of it first boots.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Provisioner::DistroRecipe};

use File::Slurper();
use HTTP::Tiny();
use IPC::Run3();
use List::Util qw{any uniq};
use Provisioner::Utils();
use Trog::HV();
use Text::Xslate();
use YAML::XS();

=head1 NAME

Provisioner::Recipe::ubuntu - what it means for a guest to be an Ubuntu guest.

=head1 SYNOPSIS

    _base:
        _global:
            distro: ubuntu

=head1 DESCRIPTION

The distribution every guest here has been built on since before there was
anywhere to say so.

See L<Provisioner::DistroRecipe> for what a distro recipe is and what it has to
answer.

=head2 The YAML is quoted by something that knows YAML

cloud-init's user-data carries an operator's own account names, GECOS fields and
contact address, and a network configuration carries whatever addresses and
search domains it was given.  A template writing those out unquoted is a
template that produces a file cloud-init rejects the moment one of them holds a
colon or an apostrophe -- and the guest then fails to boot with nothing to read.

So the structure of each document is the template, which is what makes it
readable and lets a distribution override it, and every value that is not a fixed
literal goes through the C<yaml> formatter, which is L<YAML::XS> doing the
quoting.  That is also why nothing here interpolates a bare C<[% var %]> into
YAML: Xslate escapes for HTML by default, so an ampersand in a GECOS would
arrive on the guest as C<&amp;>.

=cut

=head1 WHAT UBUNTU ANSWERS

=head2 The five answers

C<packager>, C<base_image>, C<packager_invocation>, C<packager_up_invocation>
and C<packager_remove_invocation>: apt, and the current Ubuntu LTS cloud image.

The install invocation is as forgiving as it can be made: retries, because an
apt mirror behind nginx does occasionally drop one; C<--force-confdef> and
C<--force-confold>, because a package asking which config file to keep has
nobody to ask; and C<--force-overwrite>, because two packages shipping the same
path is common enough and not worth failing an entire build over.

=cut

sub packager                   { return 'deb' }
sub release                    { return 'noble' }
sub mirror_path                { return '/ubuntu' }
sub base_image                 { my ($self) = @_; return $self->image_for( $self->release ) }
sub packager_up_invocation     { return 'DEBIAN_FRONTEND="noninteractive" apt-get upgrade -Uy' }
sub packager_remove_invocation { return 'DEBIAN_FRONTEND="noninteractive" apt-get remove -y' }

sub packager_invocation {
    return 'DEBIAN_FRONTEND="noninteractive" apt-get install -Uy -o Acquire::Retries=3 -o Dpkg::Options=--force-confdef -o Dpkg::Options=--force-confold -o Dpkg::Options=--force-overwrite --autoremove';
}

=head2 $url = $recipe->image_for($release)

Where the cloud image for a named release lives.

=head2 $url = $recipe->current_image()

The image for whichever LTS Canonical currently says is supported, or undef if
it could not be asked.  See L<Provisioner::DistroRecipe/current_image>.

=head2 $codename = $recipe->current_release()

That release's codename, out of F<meta-release-lts> -- the file Ubuntu's own
upgrader reads, so it is the answer rather than an inference from one.  The last
entry marked supported is the current one; the file lists the next LTS before it
ships, with C<Supported: 0>, which is exactly the entry a "highest version wins"
reading would pick wrongly.

Undef if the fetch fails.  Nothing here is worth failing a preflight over.

=cut

sub image_for {
    my ( $self, $release ) = @_;
    return "https://cloud-images.ubuntu.com/$release/current/$release-server-cloudimg-amd64.img";
}

sub current_image {
    my ($self) = @_;
    my $release = $self->current_release or return undef;
    return $self->image_for($release);
}

sub current_release {
    my ($self) = @_;

    my $res = HTTP::Tiny->new( timeout => 10 )->get('https://changelogs.ubuntu.com/meta-release-lts');
    return undef unless $res->{success};

    my ( $current, $dist );
    foreach my $line ( split( "\n", $res->{content} ) ) {
        $dist    = $1    if $line =~ m/\A\s*Dist:\s*(\S+)/;
        $current = $dist if $line =~ m/\A\s*Supported:\s*1\s*\z/ && defined $dist;
    }

    return $current;
}

=head2 @pkgs = $recipe->deps()

What every guest needs regardless of what is being put on it: something to make
a certificate with, ssh in both directions, rsync for the payload, retry for the
recipes that use it, and a mailer so cron and the makefile have somewhere to
send failures.

=cut

sub deps { return qw{openssl openssh-server openssh-client rsync retry sendmail} }

=head1 METHODS

=head2 BLOCK_SCALAR_INDENT

How far in the body of a C<|> block scalar starts.

YAML wants it deeper than the key that introduces it, and every C<content: |>
in the user-data sits four spaces in -- a C<- path:> entry at two, its keys at
four -- so the body has to begin at five or more.  Six is the next step on the
two-space rhythm the rest of the document keeps.

One depth, so one filter.  The rsyslog configuration was nested a level deeper
than the rest and would have needed a second filter differing only in this
number; its C<configs:> list is written at the same indent as its key instead,
which brings it back to this depth.

=cut

sub BLOCK_SCALAR_INDENT { return 6 }

=head2 @fmts = $recipe->formatters()

C<yaml> hands a value to L<YAML::XS> and puts back what it says, for the places
a document takes one -- with one correction, for a scalar PyYAML would read as
a base-60 number and libyaml would not.  C<indent> is for a whole file carried
inside another as a block scalar.

=cut

sub formatters {
    return (
        yaml   => Text::Xslate::html_builder( sub { return _yaml(shift) } ),
        indent => Text::Xslate::html_builder( sub { return _indent( shift, BLOCK_SCALAR_INDENT ) } ),
    );
}

# Everything these documents are written for is read by cloud-init, which is
# PyYAML, and PyYAML still implements YAML 1.1 sexagesimals while the libyaml
# under YAML::XS does not.  So a scalar of colon-separated numbers -- which is
# what a MAC address with no hex letters in it is -- comes back out of Dump bare,
# because libyaml sees a string, and is read on the guest as a base-60 integer.
# cloud-init then calls .lower() on it, the whole network stage dies, and the
# guest sits on systemd-networkd-wait-online forever without ever saying why.
#
# Quoting it costs nothing for the parsers that were already right.
my $SEXAGESIMAL = qr/\A[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+(?:[.][0-9_]*)?\z/;

# YAML::XS always leads with a document marker and always ends with a newline;
# neither is wanted where this is being pasted into a document that already has
# both.
sub _yaml {
    my ($value) = @_;

    my $text = YAML::XS::Dump($value);
    $text =~ s/\A---[ \t]*\n?//;
    $text =~ s/\n\z//;

    return "'$text'" if !ref $value && $text =~ $SEXAGESIMAL;
    return $text;
}

sub _indent {
    my ( $text, $indent ) = @_;
    return $text unless $indent;

    my $pad = q{ } x $indent;
    $text =~ s/^(?=.)/$pad/mg;
    return $text;
}

=head2 $hv = $recipe->hv()

The hypervisor this guest is being built for, out of the singleton the run
already established -- unless one was handed to the constructor, which is what a
test does.

Reached here rather than from L<Provisioner::Recipe>, so that loading an
ordinary recipe does not load L<Sys::Virt> along with it.

=cut

sub hv { my ($self) = @_; return $self->{hv} //= Trog::HV->new() }

=head2 %opts = $recipe->enrich(%opts)

Work out everything the five templates read that is not simply handed to every
recipe.

The two files that travel I<inside> another are rendered here rather than being
left to an ordering between C<template_files> entries: cloud-init carries the
setup script and the rsyslog configuration by value, in C<write_files>, and
nothing about C<template_files> promises which of them is rendered first.
C<render_raw> is what makes that possible without recursing back through
C<validate>; see L<Provisioner::Recipe/render_raw>.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $hv  = $self->hv;
    my $sub = $self->template_subdir;

    # Both are ours to decide, so neither has to be configured: the domain XML
    # pins the PCI slots, and systemd names a PCI NIC after its hotplug slot.
    # The MAC is what actually does the work -- cloud-init matches on it and
    # renames the interface to the name below -- so a guest whose kernel names
    # things some other way still gets the right configuration on the right
    # card.  dhcp_devname and bridge_devname override what it ends up called.
    my ( $nat_name, $bridge_name ) = $hv->nic_names;
    $opts{dhcp_devname}   //= $nat_name;
    $opts{bridge_devname} //= $bridge_name;
    $opts{nat_mac}        //= $hv->guest_mac( $opts{domain}, 0 );
    $opts{bridge_mac}     //= $hv->guest_mac( $opts{domain}, 1 );
    $opts{hv_internal_ip} //= $hv->virbr_ip;

    # Which mirror, and whether apt is allowed to install from it unverified.
    # The second follows from the first and so cannot be a schema default; see
    # Provisioner::DistroRecipe.
    $opts{mirror_uri} = $self->mirror_uri(%opts);
    $opts{mirror_insecure} //= length $opts{mirror_uri} ? 1 : 0;

    $opts{ips}       = Provisioner::Utils::coerce_arrayref( $opts{ips} );
    $opts{resolvers} = Provisioner::Utils::coerce_arrayref( $opts{resolvers} );

    die "MUST SET gateway in provision.conf when ips are set\n"
      if @{ $opts{ips} } && !( defined $opts{gateway} && length $opts{gateway} );

    die "MUST SET contact_email in provision.conf for $opts{domain}\n"
      unless defined $opts{contact_email} && length $opts{contact_email};

    $opts{guest_key} = $self->guest_keypair(%opts);
    $opts{users}     = $self->_users(%opts);
    $opts{packages}  = _first_boot_packages( $opts{packages} );

    # A list rather than two lines of the template, because the first of them
    # has a newline in the middle of it and a YAML sequence item written by hand
    # could not carry one.  The trailing space and that newline are both as they
    # have always been.
    $opts{runcmd} = [
        qq{echo "root:$opts{contact_email}\n" > /etc/aliases },
        'at now -f /root/setup.sh',
    ];

    # Straight out of the recipe's own templates, so a distribution that wants a
    # different setup script or a different log shipper writes one and gets it.
    $opts{setup_script}  = $self->render_raw( "files/$sub.setup.sh.tt",     %opts );
    $opts{rsyslog_guest} = $self->render_raw( "files/$sub.rsyslog.conf.tt", %opts );

    return %opts;
}

# What cloud-init installs before the makefile runs, which is not quite what the
# recipes asked for.
#
# atd is how the makefile gets started at all, make is what runs it, and
# something has to accept mail -- sendmail unless a recipe has asked for postfix,
# which conflicts with it.
sub _first_boot_packages {
    my ($packages) = @_;

    my @pkgs = @{ Provisioner::Utils::coerce_arrayref($packages) };
    push( @pkgs, 'sendmail' ) unless any { $_ eq 'postfix' } @pkgs;
    push( @pkgs, qw{at make} );

    return [ uniq @pkgs ];
}

# The users cloud-init is to create, with the guest's own key authorized for the
# admin among them.
#
# That key is how this machine gets back in to run the makefile again, so it goes
# on the account that can sudo rather than on root, whose login the ssh recipe
# locks down to keys anyway.
sub _users {
    my ( $self, %opts ) = @_;

    my $users = Provisioner::Utils::coerce_arrayref( $opts{users} );
    return $users unless defined $opts{admin_user};

    foreach my $user (@$users) {
        next unless ref $user eq 'HASH' && ( $user->{name} // '' ) eq $opts{admin_user};
        push( @{ $user->{ssh_authorized_keys} }, $opts{guest_key}{public} );
        last;
    }

    return $users;
}

=head2 $key = $recipe->guest_keypair(%opts)

The keypair this guest fetches its payload with, made if it has none, as a hash
of C<private>, C<public> and C<path>.

Both halves go into the guest's cloud-init, and the public one is authorized on
whichever machine is holding the payload -- which is the caller's to do, not
this recipe's, since it is a change to a machine rather than to a domain
directory.  C<bin/destroy> is what takes it back out.

A real run rotates the key, which is fine: the guest is rebuilt around whatever
is written here.  A dry run does not, because the guest that is up has the
public half of the existing one, so replacing the private half here would be
losing the way in to a machine nobody asked us to touch.  A domain with no key
yet gets one either way, since the user-data is written out of it.

=cut

sub guest_keypair {
    my ( $self, %opts ) = @_;

    my $path = "$self->{output_dir}/key.rsa";

    # This used to pipe yes(1) in to answer the overwrite prompt; removing the
    # old key first means there is no prompt.
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    unless ( $opts{dryrun} && -f $path && -f "$path.pub" ) {
        unlink $path, "$path.pub";
        IPC::Run3::run3( [ qw{ssh-keygen -t rsa -f}, $path, qw{-N}, q{}, qw{-q} ], \undef, \undef, undef );
    }

    foreach my $half ( $path, "$path.pub" ) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        die "ssh-keygen made no $half for $opts{domain}\n" unless -f $half;
        ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
        chmod 0600, $half;
    }

    return {
        path    => $path,
        private => File::Slurper::read_text($path),
        public  => ( File::Slurper::read_text("$path.pub") =~ s/\n\z//r ),
    };
}

1;
