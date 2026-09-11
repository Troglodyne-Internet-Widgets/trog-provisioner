#!/bin/bash

# build_latest_perl.sh USER [--notest] [MODULE ...]
CLIENT=$1
shift
NOTEST=
if [ "$1" = --notest ]; then
    NOTEST=--notest
    shift
fi

#XXX perlbrew = spooped when you run via clown-init
export SHELL='/bin/bash';
export HOME='/root'
export PERLBREW_ROOT='/root/perl5/perlbrew'

/bin/bash -c 'perlbrew init'

[ -f /root/perl5/perlbrew/etc/bashrc ] || exit 1;
source /root/perl5/perlbrew/etc/bashrc

WD=`dirname $(readlink -f $0)`
cd /tmp
perlbrew download stable
LATEST_TARBALL=$(ls -1 /root/perl5/perlbrew/dists/ | tail -n1)
NICE_PERL_NAME=$(echo $LATEST_TARBALL | sed 's/\.tar\.gz$//' | sed 's/-//g')

if [ ! -f /opt/perl5/$NICE_PERL_NAME/bin/perl  ]; then
    rm -rf src
    tar --one-top-level=src --strip-components=1 -zxf ~/perl5/perlbrew/dists/$LATEST_TARBALL
    cd src
    ./Configure -des -Dprefix=/opt/perl5/$NICE_PERL_NAME -Duseshrplib
    # As many jobs as the guest has processors, not eight regardless.  A guest
    # gets two by default, so -j8 put four times the work in flight as there
    # was anything to run it on -- which on a build this size costs time rather
    # than saving it.
    JOBS=$(nproc 2>/dev/null || echo 2)
    make -j"$JOBS"
    make -j"$JOBS" install

    # Its cpanm, from the App::cpanminus release tarball.
    "$WD/cpan_install" --bootstrap "/opt/perl5/$NICE_PERL_NAME/bin/perl" || exit 1
fi

# What the perl recipe says this perl comes with, installed every run rather
# than only when it is built: cpanm skips what is already there, and a module
# added to the list since reaches this guest now rather than never.  Before the
# links below, which only link what is there.
if [ $# -gt 0 ]; then
    "$WD/cpan_install" $NOTEST --perl "/opt/perl5/$NICE_PERL_NAME/bin/perl" install "$@" || exit 1
fi

CLIENT_HOMEDIR=$(getent passwd $CLIENT | cut -d: -f6);

if [ -z "$CLIENT_HOMEDIR" ]; then
	echo "build_latest_perl.sh: no such account '$CLIENT'" >&2
	exit 255
fi

# Named, because "Can't get client's homedir!" says neither which account nor
# which directory, and the answer is usually that the account is not the one the
# domain meant: a service user has the domain directory as its home and that is
# made by the service_user target, but an account like www-data has /var/www,
# which only exists if something else created it.
if [ ! -d "$CLIENT_HOMEDIR" ]; then
	echo "build_latest_perl.sh: home directory '$CLIENT_HOMEDIR' for '$CLIENT' does not exist" >&2
	exit 255
fi

# Symlinks to the perl, which is how everything else finds it --
# scripts/cpan_install through /root/bin/cpanm, and people and services through
# the user's bin.
#
# Guarded on the target existing, not just on the link being absent.  What is
# installed above is cpanminus and the perl recipe's modules, and nothing else
# -- so yath (Test2::Harness) and dzil
# (Dist::Zilla) were being linked to files that have never been there, on every
# guest that runs the perl recipe.  A link to nothing is worse than no link: it
# satisfies -e, so anything checking for the tool finds it and then fails at the
# point of use.  Whatever installs those later gets its link on the next run.
mkdir -p $CLIENT_HOMEDIR/bin
mkdir -p /root/bin
link_tool() {
	[ -e "/opt/perl5/$NICE_PERL_NAME/bin/$1" ] || return 0
	[ -L "$2/$1" ] && return 0
	ln -s "/opt/perl5/$NICE_PERL_NAME/bin/$1" "$2/$1"
}
link_tool perl "$CLIENT_HOMEDIR/bin"
link_tool prove "$CLIENT_HOMEDIR/bin"
link_tool yath "$CLIENT_HOMEDIR/bin"
link_tool dzil "$CLIENT_HOMEDIR/bin"
link_tool cpanm "$CLIENT_HOMEDIR/bin"
link_tool starman "$CLIENT_HOMEDIR/bin"
link_tool perlcritic "$CLIENT_HOMEDIR/bin"
link_tool perltidy "$CLIENT_HOMEDIR/bin"
link_tool nytprofmerge "$CLIENT_HOMEDIR/bin"
link_tool nytprofhtml "$CLIENT_HOMEDIR/bin"
link_tool perl /root/bin
link_tool cpanm /root/bin

