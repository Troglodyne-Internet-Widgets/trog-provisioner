package Trog::GuestKey;

# ABSTRACT: The key a guest is reached with, kept in the secret store.

use v5.41;

use strict;
use warnings FATAL => 'all';
use re '/aa';

use File::Temp();
use File::Slurper();
use Trog::Config();
use Trog::Credentials();
use Trog::Secrets();

=head1 NAME

Trog::GuestKey - where a domain's ssh key lives, and how to get a usable one.

=head1 SYNOPSIS

    my $path = Trog::GuestKey->path( 'vm.example.com', "$domain_dir/vm.example.com/key.rsa" );
    Trog::Guest->new( name => $domain, host => $ip, user => $admin, key_path => $path );

=head1 DESCRIPTION

The private half of the key a guest is reached with used to sit in the domain
directory as F<key.rsa>, mode 0600, from one provision until the next.  It is the
credential for the machine it belongs to, so anything that could read that
directory -- a process running as the same user, a stolen disk, a backup of
F</opt/domains> -- had the way in to every guest.

It lives in the secret store now.  What is here is the two halves of that: the
provision that makes a key puts it there, and everything that needs to use one
gets it back out.

=head2 It is still rotated every provision

The store is otherwise for secrets that are made once and answered from there
forever, and this is not one of them.  L<Provisioner::Recipe::ubuntu/guest_keypair>
mints a fresh key on every real run, deliberately -- the guest is rebuilt around
whatever cloud-init is written with -- so a key is only ever the way into the
guest that is up now.  C<seal> therefore overwrites, where L<Trog::Secrets/remember>
would keep the first answer forever.

Which means sealing does not make the key long-lived.  It moves where the current
one rests, and leaves its lifetime alone.

=head2 A guest built before this still works

C<path> hands back the file when there is one.  An installation whose domains
have a F<key.rsa> on disk goes on using it, and each domain seals itself the next
time it is provisioned -- there is nothing to migrate and no run to make first.

=cut

=head1 METHODS

=head2 $ref = Trog::GuestKey->ref_for($domain)

The reference the store keeps this domain's key under.

=cut

sub ref_for { my ( undef, $domain ) = @_; return "secret:guests/$domain/password" }

=head2 Trog::GuestKey->seal($domain, $path)

Put the private half at C<$path> into the store and take it off the disk.

Overwrites what was there: the key rotates, and the store is holding the current
one rather than the first one.  The file goes only once the store has it, so a
failure anywhere in here leaves the key where it was rather than nowhere.

=cut

sub seal {
    my ( $class, $domain, $path ) = @_;

    my $private = eval { File::Slurper::read_binary($path) };
    return 0 unless defined $private && length $private;

    Trog::Secrets->write(
        Trog::Config->path('secrets.kdbx'),
        Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
        $class->ref_for($domain) => $private,
    );

    unlink $path;
    return 1;
}

=head2 $path = Trog::GuestKey->path($domain, $on_disk)

A path to this domain's private key that ssh can be pointed at, or undef when
there is no key for it anywhere.

C<$on_disk> is where the key used to be kept, which the caller knows and this
does not: asking L<Trog::HV> would drag L<Sys::Virt> into everything that wants
to reach a guest, and where a domain directory is has never been this module's
question.  Given one that exists, that is the answer -- see L</A guest built
before this still works>.

Otherwise the store's copy, written to a temporary file that belongs to this
process and goes away with it.  Asked for twice in one run it is fetched once.

Undef rather than a die for a domain the store has never heard of: a first build
has no key yet, and the callers already treat "no key" as "use the agent or the
ssh config", which is a better answer than a path to nothing.  An installation
with no store at all is answered without asking for a password, since there is
nothing a password would open.

=cut

sub path {
    my ( $class, $domain, $on_disk ) = @_;

    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- asking whether the old location still holds one
    return $on_disk if defined $on_disk && -f $on_disk;

    state %materialised;
    return $materialised{$domain}{path} if $materialised{$domain};

    # Before the password is asked for, not after.  An installation with no
    # store cannot be holding a key, and asking would mean a prompt with nothing
    # behind it -- which in a run with nobody to type at is not a refusal, it is
    # a wait.  That is how the test suite came to hang the first time this was
    # wired up.
    my $store = Trog::Config->path('secrets.kdbx');
    ## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- whether there is a store to ask
    return undef unless defined $store && -f $store;

    my %got = eval {
        Trog::Secrets->read(
            $store,
            Trog::Credentials->prompt( 'Enter password:', 'keepass' ),
            key => $class->ref_for($domain),
        );
    };
    return undef unless $got{key};

    # Kept in the hash as well as on disk: File::Temp removes the file when the
    # object goes out of scope, so letting go of it would leave ssh pointed at a
    # path that had just been unlinked.
    my $tmp = File::Temp->new( TEMPLATE => "guest-key-$domain-XXXXXX", TMPDIR => 1 );
    chmod 0600, "$tmp";    ## no critic (Plicease::ProhibitLeadingZeros) -- a file mode, which is octal
    print {$tmp} $got{key} =~ m/\n\z/ ? $got{key} : "$got{key}\n";
    close($tmp);

    $materialised{$domain} = { handle => $tmp, path => "$tmp" };
    return $materialised{$domain}{path};
}

1;
