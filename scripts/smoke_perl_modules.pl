#!/usr/bin/perl

package Trog::Script::SmokePerlModules;

use 5.014;

use strict;
use warnings FATAL => 'all';

use Cwd          ();
use File::Find   ();
use Getopt::Long ();
use JSON::PP     ();
use POSIX        ();

=head1 smoke_perl_modules.pl

=head2 SYNOPSIS

    smoke_perl_modules.pl --forks FILE \
        --conformance-command=WORD [--conformance-command=WORD ...] \
        --install-command=WORD [--install-command=WORD ...] \
        BASEDIR CPAN_INSTALL [FLAG ...]

=head2 DESCRIPTION

Installs the dependencies of each checkout in C<BASEDIR>, then runs its tests.
C<CPAN_INSTALL> is the path of F<scripts/cpan_install>, and each C<FLAG> goes
to it before the verb, such as C<--notest>.  admincode passes its basedir.

Every checkout is tried, and the exit code says whether any failed.  The
options are required, and come before C<BASEDIR>.

=head3 Forks

C<--forks> is the cache of F<scripts/repos_for>, which records which
repositories the API calls forks.  A checkout whose name the cache records as a
fork is not smoked, because its suite is the business of the project it came
from.

=head3 System packages

The words of C<--conformance-command> run the C<conformance> program of
L<Dist::Conformance>, such as the perl that it is installed into and then its
path.  Before the dependencies of a checkout from CPAN, the script asks
C<conformance packages> which packages the F<metamerge.yml> of the checkout
declares for this host, and runs the words of C<--install-command> with those
names after them.  The install command is the C<install_command> of the
packager of the guest, which L<Provisioner::Packager> gives.  A
declaration that does not resolve for the host, or an install that fails,
fails that checkout, and the script goes on to the next.  The packages come
from the archives that the guest already has: an archive that a declaration
names in C<x_system_sources> is not added.

=head3 Whose files

The script runs as root, from the postrun of the guest, and the checkouts
belong to the admin.

The install goes into the perl of the guest, so it runs as root.  It also
writes in the checkout: Makefile.PL writes F<Makefile> and F<MYMETA.*>, and the
git that dzil plugins run rewrites F<.git/index>.  So after the install, each
file in the checkout that the script's own account owns goes to the owner of
the checkout, symlinks too.

The tests then run as the owner of the checkout, through C<cpan_install --as>,
so that nothing they write belongs to root.  A file that root owns in a checkout is one
that the admin cannot write, and a root-owned F<.git/index> stops every commit.

=head3 Whose tools

A build can run more than perl.  A dist.ini can run npm in a BeforeBuild, for
example, and C<dzil listdeps> runs it.  The toolchains that the owner works
with are the ones that the build expects: the node of nvm, the tools of
C<go install>, and whatever else a file in F<~/.bashrc.d> puts on C<PATH>.

So the install and the tests of each checkout run with the C<PATH> of an
interactive bash of its owner first, and the C<PATH> of the script after it.
The script does not ask when it runs as the owner itself, and an owner whose
bash says nothing changes nothing.

=cut

sub main {
    my @args = @_;

    # require_order, so that the flags of cpan_install after BASEDIR stay there.
    Getopt::Long::Configure('require_order');
    my ( $forks_file, @conformance, @install );
    Getopt::Long::GetOptionsFromArray( \@args, 'forks=s' => \$forks_file, 'conformance-command=s' => \@conformance, 'install-command=s' => \@install )
      or die "smoke_perl_modules: cannot read the options\n";
    die "smoke_perl_modules: --forks, --conformance-command and --install-command are required\n" unless defined $forks_file && @conformance && @install;

    my ( $basedir, $cpan_install, @flags ) = @args;
    die "Must pass repo basedir as first arg\n"         unless $basedir;
    die "Must pass the path of cpan_install after it\n" unless $cpan_install;

    my %fork = map { $_ => 1 } forks_in($forks_file);

    # One level only, so glob is enough, and * skips the dot entries.
    my @subdirs = grep { -d $_ } glob("$basedir/*");

    my $had_failures = 0;
    foreach my $repo_dir (@subdirs) {
        my $verb = verb_for($repo_dir);
        next unless $verb;

        my ($name) = $repo_dir =~ m{([^/]+)\z};
        if ( $fork{$name} ) {
            print {*STDERR} "smoke_perl_modules: $name is a fork, so it is not smoked\n";
            next;
        }

        if ( install_system_packages( \@conformance, \@install, $repo_dir ) ) {
            print {*STDERR} "smoke_perl_modules: the system packages of $repo_dir did not install, so it is not smoked\n";
            $had_failures++;
            next;
        }

        my ( $uid, $gid ) = ( stat $repo_dir )[ 4, 5 ];
        unless ( defined getpwuid $uid ) {
            print {*STDERR} "smoke_perl_modules: $repo_dir belongs to uid $uid, which no account has, so it is not smoked\n";
            $had_failures++;
            next;
        }

        # See "Whose tools".
        local $ENV{PATH} = path_with( owner_path($uid) );

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

=head2 verb_for($dir)

The verb of F<cpan_install> that installs what the checkout in C<$dir> needs:
C<dzil> for a F<dist.ini>, C<installdeps> for a F<Makefile.PL> or a
F<Build.PL>, and undef for a checkout with none of them.

    my $verb = verb_for($dir);

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

=head2 forks_in($file)

The names of the repositories that C<$file>, the cache of
F<scripts/repos_for>, records as forks, under every api_url and entity.  Dies
when C<$file> cannot be read or is not JSON.

    my @names = forks_in($file);

=cut

sub forks_in {
    my ($file) = @_;

    open( my $fh, '<', $file ) or die "smoke_perl_modules: cannot read $file, the cache of repos_for: $!\n";
    my $json = do { local $/; <$fh> };
    close($fh) or die "smoke_perl_modules: cannot close $file: $!\n";
    my $cache = eval { JSON::PP->new->utf8->decode($json) } // die "smoke_perl_modules: $file is not JSON\n";

    my @forks;
    foreach my $entities ( values %$cache ) {
        foreach my $repos ( values %$entities ) {
            push @forks, grep { $repos->{$_}{fork} } keys %$repos;
        }
    }
    return @forks;
}

=head2 install_system_packages(\@conformance, \@install, $dir)

Asks C<conformance>, which the words of C<@conformance> run, which system
packages the checkout in C<$dir> declares for this host, and runs C<@install>
with them.  See L</System packages>.  Returns 0 when that worked, or when the
checkout declares nothing, and the exit status of what failed otherwise.

    my $failed = install_system_packages(\@conformance, \@install, $dir);

=cut

sub install_system_packages {
    my ( $conformance, $install, $dir ) = @_;

    open( my $fh, '-|', @$conformance, 'packages', $dir ) or return 127;    ## no critic (ProhibitPipeOpen) -- the names conformance prints are the answer
    my @packages = map { s/\s+\z//r } <$fh>;

    # Unchecked, because close is false for any nonzero exit, which $? holds.
    close $fh;                                                              ## no critic (InputOutput::RequireCheckedSyscalls)
    return $? if $?;
    return 0 unless @packages;

    system( @$install, @packages );
    return $?;
}

=head2 as_owner($uid)

The flags of F<cpan_install> that run its tests as the account C<$uid>.  Empty
for the account that runs this script, which needs no change.  Dies for a
C<$uid> that no account has.

    my @flags = as_owner($uid);

=cut

sub as_owner {
    my ($uid) = @_;

    return if $uid == $<;
    my $name = getpwuid $uid;
    die "smoke_perl_modules: no account has uid $uid\n" unless defined $name;
    return ( '--as', $name );
}

=head2 owner_path($uid)

The C<PATH> of an interactive bash of the account C<$uid>, with the home of
that account as C<HOME>.  Nothing for the account that runs this script, and
nothing when that bash prints no C<PATH>.  See L</Whose tools>.

    my $path = owner_path($uid);

=cut

sub owner_path {
    my ($uid) = @_;

    return if $uid == $<;
    my ( $name, $home ) = ( getpwuid $uid )[ 0, 7 ];
    die "smoke_perl_modules: no account has uid $uid\n" unless defined $name;
    return interactive_path( 'runuser', '-u', $name, '--', 'env', "HOME=$home" );
}

=head2 interactive_path(@prefix)

Runs C<bash -ic> after the words in C<@prefix>, and returns the C<PATH> that
it prints.  The C<PATH> is on a line of its own, after whatever the startup
files of bash print, and the last such line counts.  Nothing when bash prints
none.

    my $path = interactive_path(@prefix);

=cut

sub interactive_path {
    my @prefix = @_;

    open( my $fh, '-|', @prefix, 'bash', '-ic', q{printf '\nPATH=%s\n' "$PATH"} ) or return;    ## no critic (ProhibitPipeOpen) -- what bash prints is the answer
    my @said = <$fh>;

    # Unchecked, because a startup file can make bash exit nonzero after it
    # printed the PATH.
    close $fh;    ## no critic (InputOutput::RequireCheckedSyscalls)
    my ($path) = reverse map { m/\APATH=(.+)\n?\z/ ? $1 : () } @said;
    return $path;
}

=head2 path_with(@paths)

Joins each C<PATH> in C<@paths>, then the C<PATH> of this script, into one,
in that order.  A directory that is already there, and an empty one, is left
out.

    my $path = path_with(@paths);

=cut

sub path_with {
    my @paths = @_;
    my %seen;
    return join ':', grep { $_ ne q{} && !$seen{$_}++ } map { split /:/ } grep { defined } @paths, $ENV{PATH};
}

=head2 give_back($dir, $from, $uid, $gid)

Gives each file and directory under C<$dir> that C<$from> owns to C<$uid> and
C<$gid>, a symlink as well.  Nothing happens when C<$from> is
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
                return if !@st || $st[4] != $from;
                set_owner( $File::Find::name, $uid, $gid );
            },
        },
        Cwd::abs_path($dir)
    );
    return;
}

=head2 set_owner($path, $uid, $gid)

lchown, which changes a symlink itself and never what it points at.  It is in a
sub of its own, so that a test can see each call without root.
Warns when the chown fails, and goes on.

=cut

sub set_owner {
    my ( $path, $uid, $gid ) = @_;
    POSIX::lchown( $uid, $gid, $path ) or warn "smoke_perl_modules: cannot give $path to $uid:$gid: $!\n";
    return;
}

exit main(@ARGV) unless caller;

1;
