package Provisioner::Utils;

#ABSTRACT: Assorted helpers shared across Provisioner modules.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aasx';

use File::Find();
use MIME::Base64 qw{encode_base64};

use Data::Validate::Email();
use URI();

# A static check cannot see these used.  The dispatch table below names the
# Crypt::PK classes as strings, and the rest are called by their full names.
## no critic (ProhibitUnusedImports)
use Crypt::PK::Ed25519();
use Net::SSH::Perl::Key();
use File::Slurper();
use File::Slurper::Temp();
use Crypt::PK::ECC();
use Crypt::PK::RSA();
## use critic

=head1 NAME

Provisioner::Utils - Odds and ends the recipes and the generator both need.

=head2 DESCRIPTION

Helpers that the recipes and the modules around them share.

=cut

=head2 SUBROUTINES

=head3 files_in($dir)

The names of the plain files directly in C<$dir>, sorted, with no leading path.

It lists the top level only, and no directories.  Every caller reads a flat
directory, for example the recipes or the scripts packed into a domain.

Returns an empty list for a directory that does not exist or that it cannot
read.  Every caller treats that the same as an empty directory.

=cut

sub files_in {
    my ($dir) = @_;
    return () unless defined $dir && -d $dir;

    my @found;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;

                # Prune each directory below the top, because the caller asks
                # about the top level only.
                ## no critic (ValuesAndExpressions::ProhibitFiletest_d, ValuesAndExpressions::ProhibitFiletest_f)
                if ( -d $path ) {
                    $File::Find::prune = 1 unless $path eq $dir;
                    return;
                }
                return unless -f $path;

                ( my $name = $path ) =~ s{\A\Q$dir\E/}{};
                push( @found, $name );
            },
        },
        $dir
    );

    my @sorted = sort @found;
    return @sorted;
}

=head3 coerce_arrayref($value)

Returns C<$value> as an arrayref.

C<Config::Simple> returns a plain string for a key with one value, and an
arrayref for a key with values separated by commas.  A person writes the
configuration of a recipe by hand.  So the same field is a list in one domain
and a string in the next.

An absent value and an empty value both return an empty arrayref.
C<Config::Simple> returns undef for a missing key and the empty string for
C<key=>, but no caller needs that difference.

=cut

sub coerce_arrayref {
    my ($value) = @_;
    return [] unless length $value;    ## no critic (ValuesAndExpressions::ProhibitDefinedBeforeLength) -- "0" is an element like any other
    return $value if ref $value eq 'ARRAY';
    return [$value];
}

=head3 dirs_in($dir)

The names of the directories directly in C<$dir>, sorted, with no leading path.

The companion of C<files_in>, with the same rules: the top level only, and an
empty list for a directory that does not exist.  Both prune instead of walk,
because the question is what is I<in> a directory, not what is under it.

=cut

sub dirs_in {
    my ($dir) = @_;
    return () unless defined $dir && -d $dir;

    my @found;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless -d $path;
                return if $path eq $dir;

                $File::Find::prune = 1;
                ( my $name = $path ) =~ s{\A\Q$dir\E/}{};
                push( @found, $name );
            },
        },
        $dir
    );

    my @sorted = sort @found;
    return @sorted;
}

=head3 lastuniq(@array)

Like C<List::Util::uniq>, but each value keeps the position of its last
occurrence, not its first.

Returns ARRAY.

=cut

sub lastuniq {
    my @input = @_;
    my %hashed;
    @hashed{@input} = 0 .. @input;
    my @out;
    for my $idx ( sort { $a <=> $b } values(%hashed) ) {
        push( @out, $input[$idx] );
    }
    return @out;
}

=head3 subdomain_aliases($domain, @recipes)

One fully qualified alias per label the recipes declare in
L<Provisioner::Recipe/subdomains>, sorted and once each: C<www> under
C<test.test> comes back as C<www.test.test>.

C<@recipes> is anything that answers C<subdomains> -- the classes
L<Provisioner::Cookbook/load> returns, or built recipe objects.

Returns ARRAY.

=cut

sub subdomain_aliases {
    my ( $domain, @recipes ) = @_;

    my %seen;

    return grep { !$seen{$_}++ } sort map {
        my $recipe = $_;
        map { "$_.$domain" } $recipe->subdomains
    } @recipes;
}

=head3 qualify_address($value, $domain)

Adds C<$domain> to a local part to make an address.  An address stays exactly
as it is.

Two recipes use this.  The mistake it prevents shows only in a mail log.  If you
add the domain to an address, you get C<somebody@example.test@this.domain>.
Postfix and cron both accept that, and neither delivers it.

Returns STRING.  Returns C<$value> unchanged if C<$value> or C<$domain> is
empty.

=cut

sub qualify_address {
    my ( $value, $domain ) = @_;

    return $value unless $value;
    return $value if Data::Validate::Email::is_email($value);
    return $value unless $domain;
    return "$value\@$domain";
}

=head3 host_of($url)

Returns the host that a URL names, or nothing if it names none.  The host of a
URL comes back in lower case.

An scp-style git address, for example C<git@github.com:o/r.git>, counts as a
URL, because gogs gives that form for a repository.

A recipe with a configured upstream passes its C<repo_url> or C<api_url> here.
The answer is the host it connects to, which it declares in C<fetch_hosts> so
that the fetch cache serves it.

=cut

sub host_of {
    my ($url) = @_;

    return unless $url;

    # Match an scp address here, because URI cannot parse one.  With a scheme
    # added, the colon after the host reads as a port, and
    # ssh://git@github.com:o/r.git gives the host "github.com:o".  Without a
    # scheme, URI returns a URI::_generic, which has no host method.
    my ($scp_host) = $url =~ m{\A[^/\s]+\@([[:alnum:]][[:alnum:].-]*):};
    return $scp_host if defined $scp_host;

    my $host = eval { URI->new($url)->host };
    return $host ? lc $host : ();
}

=head3 ($kind, $value) = fleet_address($name, %opts)

Says what C<$name> is for the guest that uses it.  C<$name> names another
machine of this installation, for example a package mirror, a log destination
or a fetch cache.  C<%opts> takes C<domain>, the guest that asks, and C<ipmap>,
the assignments of the ip pool.

Returns one of five pairs:

    none     the name is empty                          value ''
    url      it has a scheme, and is used as written    value the name
    self     it is the guest asking                     value ''
    address  the pool assigns it an address             value the address
    unknown  none of those                              value the name

The caller decides what C<unknown> means, and the callers differ for a reason.
Cloud-init runs before the guest has DNS, so a caller for cloud-init cannot use
a name and dies.  The makefile runs after the guest has resolvers, so a caller
there can use the name.

=cut

sub fleet_address {
    my ( $name, %opts ) = @_;

    return ( none => q{} ) unless $name;

    # Look for a scheme, not for dots.  A host name has dots too, and only a
    # scheme says how to connect.
    return ( url => $name ) if $name =~ m{\A[[:alpha:]][[:alnum:]+.-]*://};

    return ( self => q{} ) if $name eq ( $opts{domain} // q{} );

    my $address = ( $opts{ipmap} // {} )->{$name};
    return ( address => $address ) if $address;

    return ( unknown => $name );
}

=head3 tld_of($domain)

Returns the last label of C<$domain>, or nothing if C<$domain> has no dot.

It is here so that every caller gets the same answer, and no caller loads
another to agree.  L<Provisioner::Recipe::letsencrypt> uses it to decide if a
public CA can issue for a name.  L<Provisioner::Recipe::acmeca> limits its
intermediate to it.  L<Provisioner::DNSRecipe> uses it to find a reserved TLD.

=cut

sub tld_of {
    my ($domain) = @_;

    return unless $domain;
    my ($tld) = $domain =~ m/[.]([^.]+)\z/;

    return $tld;
}

=head3 write_pem($path, $pem, $mode)

Writes a PEM to C<$path> and sets its mode.  The PEM is a certificate, a key,
or several of them joined.  Dies if it cannot set the mode.

It writes through L<File::Slurper::Temp>, so no reader sees a partial key.  The
partial file is a temporary file, and the rename that puts it in place is
atomic.  The mode changes after the rename, so C<$path> has the mode of the
temporary file until the C<chmod> completes.

=cut

sub write_pem {
    my ( $path, $pem, $mode ) = @_;

    File::Slurper::Temp::write_binary( $path, $pem );
    chmod( $mode, $path ) or die "Could not set the mode of $path: $!\n";
    return;
}

# Wraps the body of a PEM at 64 columns, as RFC 7468 requires.
sub _rewrap_pem {
    my ($pem) = @_;

    my ( $head, $body, $tail ) = $pem =~ m{\A(-{5}BEGIN[^\n]*-{5})\n(.*)\n(-{5}END[^\n]*-{5})}
      or return $pem;

    $body =~ s/\s//g;
    return join( "\n", $head, ( $body =~ m/(\N{1,64})/g ), $tail ) . "\n";
}

=head3 write_ssh_keypair($path, $type, $bits, $comment)

Makes an ssh keypair and writes both halves.  The private key goes to C<$path>
and the public key to C<$path.pub>, in the format that C<ssh-keygen> writes.

C<$type> is a L<Net::SSH::Perl::Key> type: C<RSA>, C<Ed25519> or C<ECDSA>.
Types with only one size ignore C<$bits>.  The key never has a passphrase,
because nobody is present to type one.

Returns the public half, without its trailing newline.

The private key is rewrapped at 64 columns, and Ed25519 needs that.
L<Net::SSH::Perl::Key::Ed25519/write_private> encodes the body with
C<Crypt::Misc::encode_b64>, which never wraps.  So it writes the whole payload
on one line.  The other key types of that distribution use CryptX for the PEM,
and those come out at 64 columns.

OpenSSH reads the unwrapped form, but CryptX refuses it with
C<pem_decode_openssh failed: Invalid input packet>.  Without the rewrap,
C<ssh_pubkey_from_private> below cannot read a key that this module wrote.  RFC
7468 sets the limit at 64, so the strict reader is correct.

This is reported upstream as L<briandfoy/net-ssh-perl#76|https://github.com/briandfoy/net-ssh-perl/issues/76>.
Remove the rewrap when a release has the fix.

=cut

sub write_ssh_keypair {
    my ( $path, $type, $bits, $comment ) = @_;

    my $key = Net::SSH::Perl::Key->keygen( $type, $bits );
    $key->{comment} = $comment if defined $comment;

    $key->write_private($path);
    File::Slurper::Temp::write_text( $path, _rewrap_pem( File::Slurper::read_text($path) ) );

    my $public = $key->dump_public;
    File::Slurper::Temp::write_text( "$path.pub", "$public\n" );

    return $public;
}

# Maps the curve names of libtomcrypt to the names that OpenSSH puts on the wire.
my %ECC_CURVES = (
    secp256r1 => 'nistp256',
    secp384r1 => 'nistp384',
    secp521r1 => 'nistp521',
);

# An OpenSSH public key blob is a run of fields, each with a length in front.  A
# 'string' is a 32-bit big-endian length, then that many bytes.  An 'mpint' is
# the same, but holds a big-endian integer of minimal length.  That integer gets
# a leading zero byte when its high bit is set, so it does not read as negative.
sub _sshstr ($string) { return pack( 'N/a*', $string ) }

sub _mpint {
    my ($hex) = @_;
    $hex = "0$hex" if length($hex) % 2;
    my $bin = pack( 'H*', $hex );
    $bin =~ s{^\x00+}{};
    $bin = chr(0) . $bin if !$bin || ord( substr( $bin, 0, 1 ) ) & 0x80;
    return _sshstr($bin);
}

sub _blob_rsa {
    my ($pk) = @_;
    my $hash = $pk->key2hash();
    return ( 'ssh-rsa', _sshstr('ssh-rsa') . _mpint( $hash->{e} ) . _mpint( $hash->{N} ) );
}

sub _blob_ed25519 {
    my ($pk) = @_;
    return ( 'ssh-ed25519', _sshstr('ssh-ed25519') . _sshstr( $pk->export_key_raw('public') ) );
}

sub _blob_ecc {
    my ($pk)  = @_;
    my $curve = $pk->key2hash()->{curve_name} // '';
    my $nist  = $ECC_CURVES{ lc($curve) } or die "Unsupported ECDSA curve '$curve'";
    my $type  = "ecdsa-sha2-$nist";

    # export_key_raw() returns the uncompressed point, which is the form OpenSSH needs.
    return ( $type, _sshstr($type) . _sshstr($nist) . _sshstr( $pk->export_key_raw('public') ) );
}

# CryptX cannot detect the key type, so each importer is tried in turn.
my @IMPORTERS = (
    [ 'Crypt::PK::Ed25519', \&_blob_ed25519 ],
    [ 'Crypt::PK::ECC',     \&_blob_ecc ],
    [ 'Crypt::PK::RSA',     \&_blob_rsa ],
);

=head3 ssh_pubkey_from_private($path)

Derives the OpenSSH public key for the private key at C<$path>.  The result is
the same as C<ssh-keygen -y -f $path>, without a shell command.  It supports
RSA, Ed25519 and ECDSA (nistp256/nistp384/nistp521) keys.  It reads the classic
PEM container and the newer OPENSSH container.

The key must not have a passphrase.  The provisioner runs with nobody present,
so an encrypted key is fatal, not a prompt.

Returns STRING of the form "$type $base64", with no comment and no trailing
newline.

Dies if no importer can read the key, and gives the error of each importer.
Also dies on an ECDSA curve that is not in that list.

=cut

sub ssh_pubkey_from_private {
    my ($path) = @_;
    my @errors;
    foreach my $importer (@IMPORTERS) {
        my ( $class, $encoder ) = @$importer;
        my $pk = eval { $class->new($path) };
        if ( !$pk ) {
            push( @errors, "$class: $@" );
            next;
        }
        my ( $type, $blob ) = $encoder->($pk);
        return "$type " . encode_base64( $blob, '' );
    }
    die "Could not derive a public key from $path.  It must be an unencrypted RSA, Ed25519 or ECDSA (nistp256/384/521) private key.  Import errors: @errors";
}

1;
