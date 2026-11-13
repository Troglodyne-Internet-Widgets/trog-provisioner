#!/usr/bin/perl

package Trog::Script::SmokePerlModules;

use 5.014;

use strict;
use warnings FATAL => 'all';

use Cwd        ();
use File::Find ();

=head1 smoke_perl_modules.pl

=head2 SYNOPSIS

    smoke_perl_modules.pl BASEDIR CPAN_INSTALL [FLAG ...]

=head2 DESCRIPTION

Installs the dependencies of each checkout in C<BASEDIR>, then runs its tests.
C<CPAN_INSTALL> is the path of F<scripts/cpan_install>, and each C<FLAG> goes
to it before the verb, such as C<--notest>.  admincode passes its basedir.

Every checkout is tried, and the exit code says whether any failed.

=head3 Whose files

The script runs as root, from the postrun of the guest, and the checkouts
belong to the admin.

The install goes into the perl of the guest, so it runs as root.  It also
writes in the checkout: Makefile.PL writes F<Makefile> and F<MYMETA.*>, and the
git that dzil plugins run rewrites F<.git/index>.  So after the install, each
file in the checkout that the script's own account owns goes to the owner of
the checkout.  A symlink stays as it is, because chown follows it.

The tests then run as the owner of the checkout, through C<cpan_install --as>,
so that nothing they write belongs to root.  A file that root owns in a checkout is one
that the admin cannot write, and a root-owned F<.git/index> stops every commit.

=cut

sub main {
    my ( $basedir, $cpan_install, @flags ) = @_;

    die "Must pass repo basedir as first arg\n"         unless $basedir;
    die "Must pass the path of cpan_install after it\n" unless $cpan_install;

    # One level only, so glob is enough, and * skips the dot entries.
    my @subdirs = grep { -d $_ } glob("$basedir/*");

    my $had_failures = 0;
    foreach my $repo_dir (@subdirs) {
        my $verb = verb_for($repo_dir);
        next unless $verb;

        my ( $uid, $gid ) = ( stat $repo_dir )[ 4, 5 ];
        unless ( defined getpwuid $uid ) {
            print {*STDERR} "smoke_perl_modules: $repo_dir belongs to uid $uid, which no account has, so it is not smoked\n";
            $had_failures++;
            next;
        }

        # All of $?, so that a child killed by a signal counts as a failure.
        system( $cpan_install, @flags, $verb, $repo_dir );
        my $failed = $?;
        give_back( $repo_dir, $<, $uid, $gid );
        if ($failed) {
            $had_failures++;
            next;
        }

        if ( -d "$repo_dir/t" ) {
            system( $cpan_install, as_owner($uid), 'test', $repo_dir );
            $had_failures++ if $?;
        }
    }

    return $had_failures ? 1 : 0;
}

=head2 $verb = verb_for($dir)

The verb of F<cpan_install> that installs what the checkout in C<$dir> needs:
C<dzil> for a F<dist.ini>, C<installdeps> for a F<Makefile.PL> or a
F<Build.PL>, and undef for a checkout with none of them.

=cut

## no critic (ValuesAndExpressions::ProhibitFiletest_f) -- which build system the checkout has, not an access check
sub verb_for {
    my ($dir) = @_;

    # dist.ini first: a Dist::Zilla checkout can also carry a Makefile.PL that
    # it generated, and only dzil knows the author dependencies.  cpanm reads a
    # Build.PL as it reads a Makefile.PL.
    return 'dzil'        if -f "$dir/dist.ini";
    return 'installdeps' if -f "$dir/Makefile.PL" || -f "$dir/Build.PL";
    return;
}
## use critic

=head2 @flags = as_owner($uid)

The flags of F<cpan_install> that run its tests as the account C<$uid>.  Empty
for the account that runs this script, which needs no change.  Dies for a
C<$uid> that no account has.

=cut

sub as_owner {
    my ($uid) = @_;

    return if $uid == $<;
    my $name = getpwuid $uid;
    die "smoke_perl_modules: no account has uid $uid\n" unless defined $name;
    return ( '--as', $name );
}

=head2 give_back($dir, $from, $uid, $gid)

Gives each file and directory under C<$dir> that C<$from> owns to C<$uid> and
C<$gid>, and leaves a symlink alone.  Nothing happens when C<$from> is
C<$uid>.  When C<$dir> is itself a symlink, the walk goes through it, as the
install and the tests did.

=cut

sub give_back {
    my ( $dir, $from, $uid, $gid ) = @_;
    return if $from == $uid;

    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my @st = lstat $File::Find::name;
                return if !@st || -l _ || $st[4] != $from;
                set_owner( $File::Find::name, $uid, $gid );
            },
        },
        Cwd::abs_path($dir)
    );
    return;
}

=head2 set_owner($path, $uid, $gid)

chown, in a sub of its own so that a test can see each call without root.
Warns when the chown fails, and goes on.

=cut

sub set_owner {
    my ( $path, $uid, $gid ) = @_;
    chown( $uid, $gid, $path ) or warn "smoke_perl_modules: cannot give $path to $uid:$gid: $!\n";
    return;
}

exit main(@ARGV) unless caller;

1;
