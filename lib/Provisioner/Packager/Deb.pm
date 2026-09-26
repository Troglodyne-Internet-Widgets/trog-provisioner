package Provisioner::Packager::Deb;

#ABSTRACT: Packages for the Debian family: apt archives, pins and debconf answers.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use feature 'state';

use parent qw{Provisioner::Packager};

use HTTP::Tiny();
use JSON::Validator();
use List::Util   qw{uniq};
use MIME::Base64 qw{encode_base64};
use URI();

=head1 NAME

Provisioner::Packager::Deb - Packages for the Debian family: apt archives, pins
and debconf answers.

=head1 SYNOPSIS

    my @files = Provisioner::Packager::Deb->first_boot_files( domain => $fqdn, sources => \@sources, conflicts => \@conflicts );

=head1 DESCRIPTION

The packager of L<Provisioner::Packager> for Ubuntu and Debian.  A source is an
apt archive, as below, and a recipe names it in
L<Provisioner::Recipe/package_sources>.  This module turns the sources into
three kinds of file: the signing key, a F<.sources> file in deb822 form, and a
pin.  It keeps a conflict out with a pin of its own.  The distro recipe writes
the files into the user-data of the guest, so cloud-init has the archives
before it installs the packages.

The keys are fetched here, on the machine that generates the configuration,
because cloud-init cannot fetch a key from a URL.

=head2 A source

A hash reference with these keys:

=over 4

=item C<name>

The base name of each file.  Lower case letters, digits, dots and dashes.

=item C<uri>

The archive, as C<http> or C<https>.

=item C<suites>, C<components>

Array references.  One suite at least.

=item C<key>

The URL of the signing key, armored or binary.

=item C<architectures>

Optional.  An array reference, for an archive that does not publish every
architecture.

=item C<pin>

Optional.  A hash reference with C<priority>, and C<packages>, which defaults
to C<*>.  It pins by the host of C<uri>.

=back

=cut

# The first line of an armored key, which apt reads from a .asc.
my $ARMORED = qr/\A\s*-----BEGIN[ ]PGP[ ]PUBLIC[ ]KEY[ ]BLOCK-----/;

my %SCHEMA = (
    type                 => 'object',
    required             => [qw{name uri suites components key}],
    additionalProperties => 0,
    properties           => {
        name          => { type => 'string', pattern  => '^[a-z0-9][a-z0-9.-]*$' },
        uri           => { type => 'string', pattern  => '^https?://[^/]+' },
        key           => { type => 'string', pattern  => '^https?://[^/]+' },
        suites        => { type => 'array',  minItems => 1, items => { type => 'string', pattern => '^[^\s]+$' } },
        components    => { type => 'array',  items    => { type => 'string', pattern => '^[^\s]+$' } },
        architectures => { type => 'array',  items    => { type => 'string', pattern => '^[a-z0-9]+$' } },
        pin           => {
            type                 => 'object',
            required             => ['priority'],
            additionalProperties => 0,
            properties           => {
                priority => { type => 'integer' },
                packages => { type => 'string', default => '*' },
            },
        },
    },
);

=head1 METHODS

=head2 @files = Provisioner::Packager::Deb->first_boot_files(%args)

The files of C<files> for the C<sources> in C<%args>, and the pin of C<forbid>
for its C<conflicts>, for C<domain>.  See L<Provisioner::Packager>.

=cut

sub first_boot_files {
    my ( $class, %args ) = @_;
    return (
        $class->files( $class->merge( @{ $args{sources} // [] } ) ),
        $class->forbid( $args{domain}, sort( uniq( @{ $args{conflicts} // [] } ) ) ),
    );
}

=head2 @answers = Provisioner::Packager::Deb->answers(@answers)

The answers once each, as lines that C<debconf-set-selections> reads.
cloud-init gives them to debconf before it installs anything.

=cut

sub answers {
    my ( $class, @answers ) = @_;
    return uniq @answers;
}

=head2 @modules = Provisioner::Packager::Deb->cloud_init_modules()

C<cc_apt_configure>, which sets the debconf answers.  The archives are files,
which C<cc_write_files> writes for every packager.

=cut

sub cloud_init_modules {
    return qw{cc_apt_configure};
}

=head2 @sources = Provisioner::Packager::Deb->merge(@sources)

Returns C<@sources> validated, with one entry for each C<name>.  Two recipes can
name the same archive, and then they must describe it the same way.

Dies on a source that does not match L</A source>, and on two different sources
under one name.

=cut

sub merge {
    my ( $class, @sources ) = @_;

    my $validator = JSON::Validator->new->schema( \%SCHEMA );
    my ( %by_name, @order );
    foreach my $source (@sources) {
        my $label = ref $source eq 'HASH' && defined $source->{name} ? $source->{name} : 'an apt source';
        if ( my @errors = $validator->validate($source) ) {
            die "$label is not a valid apt source:\n" . join( q{}, map { "  $_\n" } @errors );
        }
        my %normal = ( %$source, ( $source->{pin} ? ( pin => { packages => q{*}, %{ $source->{pin} } } ) : () ) );
        my $name   = $normal{name};
        if ( my $had = $by_name{$name} ) {
            die "Two recipes name the apt source $name, and they describe it differently.\n" unless _same( $had, \%normal );
            next;
        }
        $by_name{$name} = \%normal;
        push @order, $name;
    }
    return map { $by_name{$_} } @order;
}

sub _same {
    my ( $one, $two ) = @_;
    return _canonical($one) eq _canonical($two);
}

sub _canonical {
    my ($value) = @_;
    return join( ',', map { "$_=" . _canonical( $value->{$_} ) } sort keys %$value ) if ref $value eq 'HASH';
    return join( ',', map { _canonical($_) } @$value )                               if ref $value eq 'ARRAY';
    return $value // q{};
}

=head2 @files = Provisioner::Packager::Deb->files(@sources)

Fetches the key of each source, asks the archive for each suite, and returns
the files for them.  Each file is a hash reference with C<path>, C<content>,
C<permissions>, and C<encoding>, which is C<b64> for a binary key and absent
otherwise.

A key is fetched once for each process, however many domains name it.

Dies when a key cannot be fetched or is not a PGP key, and when the archive
does not answer for a suite.  A guest that boots with either fails in its
package install, where the error names neither the archive nor the key.

=cut

sub files {
    my ( $class, @sources ) = @_;

    my @files;
    foreach my $source (@sources) {
        my $name = $source->{name};
        my $key  = key( $source->{key}, $name );
        foreach my $suite ( @{ $source->{suites} } ) {
            check_suite( $source->{uri}, $suite, $name );
        }

        my $armored = $key =~ $ARMORED;
        my $keyring = "/etc/apt/keyrings/$name." . ( $armored ? 'asc' : 'gpg' );
        push @files, {
            path        => $keyring,
            permissions => '0644',
            ( $armored ? ( content => $key ) : ( content => encode_base64($key), encoding => 'b64' ) ),
        };

        my @lines = (
            'Types: deb',
            "URIs: $source->{uri}",
            'Suites: ' . join( q{ }, @{ $source->{suites} } ),
            'Components: ' . join( q{ }, @{ $source->{components} } ),
            ( $source->{architectures} ? 'Architectures: ' . join( q{ }, @{ $source->{architectures} } ) : () ),
            "Signed-By: $keyring",
        );
        push @files, { path => "/etc/apt/sources.list.d/$name.sources", permissions => '0644', content => join( "\n", @lines ) . "\n" };

        if ( my $pin = $source->{pin} ) {
            my $host = URI->new( $source->{uri} )->host;
            push @files, {
                path        => "/etc/apt/preferences.d/$name.pref",
                permissions => '0644',
                content     => "Package: $pin->{packages}\nPin: origin $host\nPin-Priority: $pin->{priority}\n",
            };
        }
    }
    return @files;
}

=head2 @files = Provisioner::Packager::Deb->forbid($domain, @packages)

A pin that keeps apt from installing C<@packages> at all, from any archive, as
the one file in a list, or no file when C<@packages> is empty.  The file is
named for C<$domain>, because a domain added to a guest that is up writes its
own, and must not replace the pin of the domain that the guest was built for.

A pin does not remove a package that is installed.  It keeps a package that
another one merely recommends, or offers as one of several choices, from being
installed.  A package that depends on a forbidden one outright cannot install
either, and apt says so.

=cut

sub forbid {
    my ( $class, $domain, @packages ) = @_;
    return () unless @packages;
    return {
        path        => "/etc/apt/preferences.d/$domain-conflicts.pref",
        permissions => '0644',
        content     => "Package: @packages\nPin: release a=*\nPin-Priority: -1\n",
    };
}

=head2 $key = key($url, $name)

The key at C<$url>, as bytes.  C<$name> is the source that wants it, for the
error.  Dies when the fetch fails, and when the answer is neither an armored
nor a binary PGP key.  A captive portal answers C<200> with a page of HTML.

=cut

sub key {
    my ( $url, $name ) = @_;

    state %keys;
    return $keys{$url} //= do {
        my $res = fetch($url);
        die "Could not fetch the signing key of the apt source $name from $url: $res->{status} $res->{reason}\n"
          unless $res->{success};
        my $body    = $res->{content} // q{};
        my $armored = $body =~ $ARMORED;

        # Bit 7 is set on the first byte of every OpenPGP packet.
        my $binary = length $body && ( ord($body) & 0x80 );
        die "What $url returned is not a PGP key, so it cannot sign the apt source $name.\n"
          unless $armored || $binary;
        $body;
    };
}

=head2 check_suite($uri, $suite, $name)

Dies unless the archive at C<$uri> has a signed index for C<$suite>.  An archive
often lacks a suite for a new release of the distribution, and MariaDB has
none for a release older than the distribution.

=cut

sub check_suite {
    my ( $uri, $suite, $name ) = @_;

    state %seen;
    my $index = ( $uri =~ s{/+\z}{}r ) . "/dists/$suite/InRelease";
    return 1 if $seen{$index};

    my $res = fetch( $index, 'HEAD' );
    die "The apt source $name has no suite $suite: $index answered $res->{status} $res->{reason}.\n"
      unless $res->{success};
    return $seen{$index} = 1;
}

=head2 $res = fetch($url, $method)

An L<HTTP::Tiny> response for C<$url>, by C<GET> unless C<$method> says
otherwise.  The one place this module reaches the network, so a test replaces
it.

=cut

sub fetch {
    my ( $url, $method ) = @_;
    return HTTP::Tiny->new( timeout => 30 )->request( $method // 'GET', $url );
}

1;
