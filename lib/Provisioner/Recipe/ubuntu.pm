package Provisioner::Recipe::ubuntu;

#ABSTRACT: Ubuntu: the image, the packager, and how a guest of it first boots.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Provisioner::DistroRecipe};

# What ssh-keygen defaults to for RSA.
my $RSA_BITS = 3072;

use File::Slurper();
use HTTP::Tiny();
use List::Util qw{any uniq};
use Provisioner::Utils();
use Text::Xslate();
use YAML::XS();

=head1 NAME

Provisioner::Recipe::ubuntu - what it means for a guest to be an Ubuntu guest.

=head1 SYNOPSIS

    _base:
        _global:
            distro: ubuntu

=head1 DESCRIPTION

The distribution that every guest here runs.

See L<Provisioner::DistroRecipe> for what a distro recipe is and what it must
answer.

=head2 The YAML is quoted by something that knows YAML

The user-data for cloud-init holds account names, GECOS fields and a contact
address from the operator.  A network configuration holds the addresses and
search domains that it was given.  If a template writes those without quotes,
cloud-init rejects the file when one of them holds a colon or an apostrophe.
The guest then does not boot, and nothing tells you why.

So the template gives the structure of each document.  That keeps it readable,
and a distribution can override it.  Every value that is not a fixed literal
goes through the C<yaml> formatter, where L<YAML::XS> does the quoting.

That is also why nothing here puts a bare C<[% var %]> into YAML.  Xslate
escapes for HTML by default, so an ampersand in a GECOS field arrives on the
guest as C<&amp;>.

=cut

=head1 WHAT UBUNTU ANSWERS

=head2 The five answers

C<packager>, C<base_image>, C<packager_invocation>, C<packager_up_invocation>
and C<packager_remove_invocation>.  The packages are deb packages, installed
with apt-get.  The image is the cloud image for the release that C<release>
pins.

The install invocation accepts as much as it can:

=over 4

=item * C<Acquire::Retries=3>, because an apt mirror behind nginx sometimes
drops a request.

=item * C<--force-confdef> and C<--force-confold>, because nobody is there to
answer when a package asks which configuration file to keep.

=item * C<--force-overwrite>, because two packages often ship the same path,
and that is not a reason to fail a build.

=back

=for Pod::Coverage release

=cut

# The version of each release that the image catalogs name it by.
my %VERSION_OF = ( jammy => '22.04', noble => '24.04', plucky => '25.04', questing => '25.10', resolute => '26.04' );

sub packager                   { return 'deb' }
sub release                    { return 'noble' }
sub mirror_path                { return '/ubuntu' }
sub base_image                 { my ($self) = @_; return $self->image_for( $self->release ) }
sub packager_up_invocation     { return 'DEBIAN_FRONTEND="noninteractive" apt-get upgrade -Uy' }
sub packager_remove_invocation { return 'DEBIAN_FRONTEND="noninteractive" apt-get remove -y' }

sub packager_invocation {
    return 'DEBIAN_FRONTEND="noninteractive" apt-get install -Uy -o Acquire::Retries=3 -o Dpkg::Options=--force-confdef -o Dpkg::Options=--force-confold -o Dpkg::Options=--force-overwrite --autoremove';
}

=head2 $version = $recipe->release_version()

The version of the release that C<release> pins, such as C<24.04> for C<noble>.
Dies for a release this does not know the version of, rather than guessing at
an image name from a codename.

=cut

sub release_version {
    my ($self) = @_;
    my $release = $self->release;
    return $VERSION_OF{$release} // die "The ubuntu recipe does not know the version of the release '$release'; add it to \%VERSION_OF\n";
}

=head2 $url = $recipe->image_for($release)

Returns the URL of the cloud image for the named release.

=cut

sub image_for {
    my ( $self, $release ) = @_;
    return "https://cloud-images.ubuntu.com/$release/current/$release-server-cloudimg-amd64.img";
}

=head2 $url = $recipe->current_image()

Returns the image for the LTS release that Canonical now says is supported.
Returns undef if the request fails.  See
L<Provisioner::DistroRecipe/current_image>.

=cut

sub current_image {
    my ($self) = @_;
    my $release = $self->current_release or return undef;
    return $self->image_for($release);
}

=head2 $codename = $recipe->current_release()

Returns the codename of that release, from F<meta-release-lts>.  The Ubuntu
upgrader reads that file, so it gives the answer directly.  The current release
is the last entry marked supported.

The file lists the next LTS before its release, with C<Supported: 0>.  A parser
that takes the highest version picks that entry, which is wrong.

Returns undef if the fetch fails, or if no entry is marked supported.  Nothing
here is worth failing a preflight over.

=cut

sub current_release {
    my ($self) = @_;

    my $res = HTTP::Tiny->new( timeout => 10 )->get('https://changelogs.ubuntu.com/meta-release-lts');
    return undef unless $res->{success};

    my ( $current, $dist );
    foreach my $line ( split( m/\n/, $res->{content} ) ) {
        $dist    = $1    if $line =~ m/\A\s*Dist:\s*(\S+)/;
        $current = $dist if $line =~ m/\A\s*Supported:\s*1\s*\z/ && defined $dist;
    }

    return $current;
}

=head2 @pkgs = $recipe->deps()

Returns what every guest needs, whatever else goes on it.  That is C<openssl> to
make a certificate, ssh as server and client, rsync for the payload, and retry
for the recipes that use it.  It also has sendmail, so that cron and the
makefile can send failures somewhere.  F<scripts/post_install> keeps its queue
in SQLite, through the C<DBI> of the system perl, and C<sqlite3> reads it.

=cut

sub deps { return qw{openssl openssh-server openssh-client rsync retry sendmail sqlite3 libdbd-sqlite3-perl} }

=head1 METHODS

=head2 BLOCK_SCALAR_INDENT

Returns the indent of the body of a C<|> block scalar.

YAML wants the body deeper than the key that starts it.  Every C<content: |>
in the user-data is four spaces in.  A C<- path:> entry is at two, and its keys
are at four.  So the body must start at five or more.  Six is the next step of
the two-space indent that the rest of the document uses.

There is one depth, so there is one filter.  For that reason, everything that
this document carries by value is at that depth.  A block one level deeper
needs a second filter that differs from this one only in a number.

=cut

sub BLOCK_SCALAR_INDENT { return 6 }

=head2 @fmts = $recipe->formatters()

Returns two formatters.  C<yaml> gives a value to L<YAML::XS> and returns what
it writes, for the places in a document that take a value.  It also quotes a
scalar that PyYAML reads as a base-60 number and libyaml does not.  C<indent>
indents a whole file that another file carries as a block scalar.

=cut

sub formatters {
    return (
        yaml   => Text::Xslate::html_builder( sub { return _yaml(shift) } ),
        indent => Text::Xslate::html_builder( sub { return _indent( shift, BLOCK_SCALAR_INDENT ) } ),
    );
}

# cloud-init reads these documents with PyYAML, which reads YAML 1.1
# sexagesimals.  The libyaml under YAML::XS does not, so Dump leaves
# colon-separated numbers unquoted, as in a MAC address with no hex letters.
# PyYAML reads that as a base-60 integer, and the network stage of cloud-init
# dies on .lower().
# The guest then waits on systemd-networkd-wait-online forever.
my $SEXAGESIMAL = qr/\A[-+]?\d[\d_]*(?::[0-5]?\d)+(?:[.][\d_]*)?\z/;

=head2 $text = _yaml($value)

Returns C<$value> as YAML, without the document marker and the final newline
that L<YAML::XS> always adds.  The document that the text goes into already has
both.  A scalar that matches C<$SEXAGESIMAL> comes back in single quotes.

=cut

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
    $text =~ s/^(?=\N)/$pad/mg;
    return $text;
}

=head2 $hv = $recipe->hv()

Returns the hypervisor that this guest is built for, as given to the
constructor.

The recipe does not call C<Trog::HV-E<gt>new()> itself.  That puts the recipe
layer before the machine layer in the load order, and an ordinary recipe then
loads L<Sys::Virt>.  Nothing here loads L<Trog::HV>.  It only uses its
interface.

C<bin/new_config> gives one to every builder it makes.  C<bin/provision> gives
one to the builder that it makes itself.  Dies if there is none, because a
hypervisor chosen here is a second answer to a question that placement settled.

=cut

sub hv {
    my ($self) = @_;

    return $self->{hv} // die ref($self) . " was built without a hypervisor: whoever builds it has to hand one over\n";
}

=head2 %opts = $recipe->enrich(%opts)

Returns C<%opts> with the values added that the four templates read and that
not every recipe gets.

The setup script goes I<inside> another file, not beside it.  cloud-init
carries it by value, in C<write_files>.  So this method renders it, because the
order of C<template_files> entries does not say which one renders first.
C<render_raw> renders it without a second pass through C<validate>.  See
L<Provisioner::Recipe/render_raw>.

Dies if C<ips> is set without C<gateway>, or if C<contact_email> is not set.

=cut

sub enrich {
    my ( $self, %opts ) = @_;

    my $hv  = $self->hv;
    my $sub = $self->template_subdir;

    # We define the machine, so we know all four values.  The domain XML pins the
    # PCI slots, and systemd names a PCI NIC after its hotplug slot.  cloud-init
    # matches on the MAC and renames the interface.  So the right card gets the
    # configuration, whatever the kernel calls it.
    #
    # A service that builds a guest by API assigns the MAC, and the image picks
    # the name.  So they stay unset, and the network-config leaves the network
    # to the platform, as a cloud image expects.
    unless ( $hv->builds_by_api ) {
        my ( $nat_name, $bridge_name ) = $hv->nic_names;
        $opts{dhcp_devname}   //= $nat_name;
        $opts{bridge_devname} //= $bridge_name;
        $opts{nat_mac}        //= $hv->guest_mac( $opts{domain}, 0 );
        $opts{bridge_mac}     //= $hv->guest_mac( $opts{domain}, 1 );
    }

    # mirror_insecure follows from mirror_uri, so it cannot be a schema default.
    # See Provisioner::DistroRecipe.
    $opts{mirror_uri} = $self->mirror_uri(%opts);
    $opts{mirror_insecure} //= $opts{mirror_uri} ? 1 : 0;

    $opts{ips}       = Provisioner::Utils::coerce_arrayref( $opts{ips} );
    $opts{resolvers} = Provisioner::Utils::coerce_arrayref( $opts{resolvers} );

    die "MUST SET gateway in provision.conf when ips are set\n"
      if @{ $opts{ips} } && !$opts{gateway};

    die "MUST SET contact_email in provision.conf for $opts{domain}\n"
      unless $opts{contact_email};

    $opts{guest_key} = $self->guest_keypair(%opts);
    $opts{users}     = $self->_users(%opts);
    $opts{packages}  = _first_boot_packages( $opts{packages} );

    # A list, not two lines of the template, because the first item has a
    # newline in it.  A YAML sequence item written by hand cannot carry one.
    $opts{runcmd} = [
        qq{echo "root:$opts{contact_email}\n" > /etc/aliases },
        q{echo 'bash /root/setup.sh' | at now},
    ];

    # From the templates of the recipe, so a distribution can have its own.
    $opts{setup_script} = $self->render_raw( "files/$sub.setup.sh.tt", %opts );

    return %opts;
}

=head2 $pkgs = _first_boot_packages($packages)

Returns the packages that cloud-init installs before the makefile runs.  That
is C<$packages>, plus what the makefile needs.  atd starts the makefile, make
runs it, and bash is the shell for recipe lines.

Something must also accept mail.  So it adds sendmail, unless C<$packages>
has postfix, which conflicts with it.

=cut

sub _first_boot_packages {
    my ($packages) = @_;

    my @pkgs = @{ Provisioner::Utils::coerce_arrayref($packages) };
    push( @pkgs, 'sendmail' ) unless any { $_ eq 'postfix' } @pkgs;
    push( @pkgs, qw{at bash make} );

    return [ uniq @pkgs ];
}

=head2 $users = $recipe->_users(%opts)

Returns the users that cloud-init creates.  The public half of the guest key is
added to the C<ssh_authorized_keys> of the user named C<admin_user>.

That key is how this machine gets back in to run the makefile again.  It goes
on the account that can sudo, not on root.  The makefile limits the root login
to keys.

=cut

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

Returns the keypair that this guest fetches its payload with, as a hash of
C<private>, C<public> and C<path>.  Makes the pair if the domain has none.
Dies if a half of the pair is still missing after that.

Both halves go into the cloud-init of the guest.  The caller authorizes the
public half on the machine that holds the payload.  That is a change to a
machine, not to a domain directory, so this recipe does not make it.
C<bin/destroy> takes it back out.

L<Provisioner::Utils/write_ssh_keypair> writes the pair in perl, not with
C<ssh-keygen>.  It also has the one fact about writing these that is not
obvious.

A domain that has a keypair keeps it.  The key identifies the machine, not the
build, and a rebuilt guest keeps the key that it was seeded with.  A new key
locks out whoever holds the old one.

A domain with no pair gets a new one, because the user-data is written from it.
C<Trog::Guest::seal_key> removes the private half from the disk.  So before the
call, the caller must put a sealed key back beside its public half.

=cut

sub guest_keypair {
    my ( $self, %opts ) = @_;

    my $path = "$self->{output_dir}/key.rsa";

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
    unless ( -f $path && -f "$path.pub" ) {
        unlink $path, "$path.pub";
        Provisioner::Utils::write_ssh_keypair( $path, RSA => $RSA_BITS, $opts{domain} );
    }

    foreach my $half ( $path, "$path.pub" ) {
        ## no critic (ValuesAndExpressions::ProhibitFiletest_f)
        die "No $half was made for $opts{domain}\n" unless -f $half;
        chmod 0600, $half;
    }

    return {
        path    => $path,
        private => File::Slurper::read_text($path),
        public  => ( File::Slurper::read_text("$path.pub") =~ s/\n\z//r ),
    };
}

1;
