package Provisioner::Utils;

#ABSTRACT: Assorted helpers shared across Provisioner modules.

use 5.041;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use File::Find();
use List::Util   qw{any};
use MIME::Base64 qw{encode_base64};

use Data::Validate::Email();

# Named as strings in the dispatch table below, never as code, so nothing static
# can see that loading them is the whole point.
## no critic (ProhibitUnusedImports)
use Crypt::PK::Ed25519();
use Net::SSH::Perl::Key();
use File::Slurper();
use File::Slurper::Temp();
use Crypt::PK::ECC();
use Crypt::PK::RSA();
## use critic

# Helpers used across various modules

=head1 NAME

Provisioner::Utils - Odds and ends the recipes and the generator both need.

=head2 DESCRIPTION

Provisioner::Recipe helpers.

=cut

=head2 SUBROUTINES

=head3 already_required($module)

Avoid double-require sub redefs.

Returns BOOLEAN.

=cut

sub already_required {
    my $module    = shift;
    my @available = keys(%INC);
    return 1 if any { m/\Q$module\E/ } @available;
    return 0;
}

=head3 files_in($dir)

The names of the plain files directly in C<$dir>, sorted, with no leading path.

Top level only, and no directories: every caller here is reading a flat
directory -- the recipes, the scripts that get packed into a domain -- and a
nested file is not one of the things they are looking for.

Returns nothing for a directory that is not there or cannot be read, which is
the same answer as one holding nothing and is what every caller wants.

=cut

sub files_in {
    my ($dir) = @_;
    ## no critic (ValuesAndExpressions::ProhibitFiletest_d)
    return () unless defined $dir && -d $dir;

    my @found;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;

                # Everything below the top is pruned rather than walked: these
                # are flat directories and walking one that is not would be a
                # different question than the caller asked.
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

    return sort @found;
}

=head3 coerce_arrayref($value)

C<$value> as an arrayref, whatever it arrived as.

C<Config::Simple> hands back a bare string for a single-valued key and an
arrayref for a comma separated one, and a recipe's configuration is written by
hand -- so the same field is a list in one domain and a string in the next.
Everything downstream wants a list.

An absent value and one that is present and empty both come back as an empty
list.  C<Config::Simple> tells those apart -- a missing key is undef, a bare
C<key=> is the empty string -- and nothing that asks this cares.

=cut

sub coerce_arrayref {
    my ($value) = @_;
    return [] unless defined $value && length $value;
    return $value if ref $value eq 'ARRAY';
    return [$value];
}

=head3 dirs_in($dir)

The names of the directories directly in C<$dir>, sorted, with no leading path.

C<files_in>'s other half, and the same rules: top level only, and nothing for a
directory that is not there.  Both prune rather than walk, because the question
is what is I<in> a directory rather than what is under it.

=cut

sub dirs_in {
    my ($dir) = @_;
    ## no critic (ValuesAndExpressions::ProhibitFiletest_d)
    return () unless defined $dir && -d $dir;

    my @found;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                ## no critic (ValuesAndExpressions::ProhibitFiletest_d)
                return unless -d $path;
                return if $path eq $dir;

                $File::Find::prune = 1;
                ( my $name = $path ) =~ s{\A\Q$dir\E/}{};
                push( @found, $name );
            },
        },
        $dir
    );

    return sort @found;
}

=head3 lastuniq(@array)

List::Util::uniq, but with the last occurrence's order preserved instead of the first.

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

=head3 qualify_address($value, $domain)

A local part becomes an address in C<$domain>; an address is left exactly as it
stands.

Two recipes need this and it is easy to get wrong in the direction that only
shows up in a mail log: appending the domain to something that is already an
address gives C<somebody@example.com@this.domain>, which postfix and cron both
accept and neither delivers.

Returns STRING, or C<$value> unchanged when there is nothing to qualify it with.

=cut

sub qualify_address {
    my ( $value, $domain ) = @_;

    return $value unless defined $value && length $value;
    return $value if Data::Validate::Email::is_email($value);
    return $value unless defined $domain && length $domain;
    return "$value\@$domain";
}

=head3 write_ssh_keypair($path, $type, $bits, $comment)

Make an ssh keypair and write both halves: the private key to C<$path> and the
public one to C<$path.pub>, in the form C<ssh-keygen> would have written them.

C<$type> is a L<Net::SSH::Perl::Key> type -- C<RSA>, C<Ed25519>, C<ECDSA> --
and C<$bits> is ignored by the types that have only one size.  The key is
always passphrase-less: nothing here runs with somebody there to type one in.

Returns the public half, without its trailing newline.

B<Ed25519 private keys are rewrapped on the way out, and that is not
cosmetic.>  L<Net::SSH::Perl::Key::Ed25519/write_private> encodes the body with
C<Crypt::Misc::encode_b64>, which never wraps, so it emits the whole payload on
one line -- every other key type in that distribution hands PEM generation to
CryptX and comes out at 64 columns.  OpenSSH reads the unwrapped form quite
happily; CryptX refuses it as C<pem_decode_openssh failed: Invalid input
packet>, which means C<ssh_pubkey_from_private> below cannot read back a key this
module just wrote.  RFC 7468 puts the limit at 64, so the strict reader is the
correct one.

Reported upstream as L<briandfoy/net-ssh-perl#76|https://github.com/briandfoy/net-ssh-perl/issues/76>;
the rewrap goes when there is a release with the fix in it.

=cut

# PEM at 64 columns, which is what RFC 7468 asks for.
sub _rewrap_pem {
    my ($pem) = @_;

    my ( $head, $body, $tail ) = $pem =~ m{\A(-{5}BEGIN[^\n]*-{5})\n(.*)\n(-{5}END[^\n]*-{5})}s
      or return $pem;

    $body =~ s/\s//g;
    return join( "\n", $head, ( $body =~ m/(.{1,64})/g ), $tail ) . "\n";
}

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

=head3 ssh_pubkey_from_private($path)

Derive the OpenSSH public key for the private key stored at $path, equivalent to
C<ssh-keygen -y -f $path> but without shelling out.  RSA, Ed25519 and ECDSA
(nistp256/nistp384/nistp521) keys are supported, in both the classic PEM and the
newer OPENSSH private key containers.

The key must not be passphrase-protected; the provisioner runs unattended, so an
encrypted key is fatal rather than an interactive prompt.

Returns STRING of the form "$type $base64", with no trailing comment or newline.

=cut

# libtomcrypt curve names to the names OpenSSH puts on the wire
my %ECC_CURVES = (
    secp256r1 => 'nistp256',
    secp384r1 => 'nistp384',
    secp521r1 => 'nistp521',
);

# An OpenSSH public key blob is a run of length-prefixed fields.  A 'string' is
# a 32bit big-endian length followed by that many bytes; an 'mpint' is the same,
# but holding a minimal-length big-endian integer which gets a leading zero byte
# when its high bit is set (so it isn't read back as negative).
sub _sshstr { return pack( 'N/a*', $_[0] ) }

sub _mpint {
    my ($hex) = @_;
    $hex = "0$hex" if length($hex) % 2;
    my $bin = pack( 'H*', $hex );
    $bin =~ s{^\x00+}{};
    $bin = "\x00$bin" if !length($bin) || ord( substr( $bin, 0, 1 ) ) & 0x80;
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

    # export_key_raw() hands back the uncompressed point, which is what OpenSSH wants
    return ( $type, _sshstr($type) . _sshstr($nist) . _sshstr( $pk->export_key_raw('public') ) );
}

# CryptX has no way to sniff the key type, so try each importer in turn
my @IMPORTERS = (
    [ 'Crypt::PK::Ed25519', \&_blob_ed25519 ],
    [ 'Crypt::PK::ECC',     \&_blob_ecc ],
    [ 'Crypt::PK::RSA',     \&_blob_rsa ],
);

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
