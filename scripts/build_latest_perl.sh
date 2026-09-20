#!/bin/bash

# build_latest_perl.sh [VERSION]
#
# Build a perl into /opt/perl5 and give it cpanm, Module::Build and
# Dist::Zilla.  The target of the perl recipe installs its cpan_deps after this.
#
# VERSION is a release, such as 5.40.2.  Without one this builds the latest
# stable, which is what the name says and what a guest got before the version
# could be configured.
#
# The perl that this built is the one everything else installs into: the
# symlink /opt/perl5/current points at it, and scripts/cpan_install follows
# that.  Without the symlink cpan_install takes the newest under /opt/perl5,
# which is the same perl on a guest that has only one.  A person finds it
# through profile.d.

# perlbrew fails under cloud-init without these.
export SHELL='/bin/bash';
export HOME='/root'
export PERLBREW_ROOT='/root/perl5/perlbrew'

/bin/bash -c 'perlbrew init'

[ -f /root/perl5/perlbrew/etc/bashrc ] || exit 1;
source /root/perl5/perlbrew/etc/bashrc

WD=`dirname $(readlink -f $0)`
WANTED="$1"
cd /tmp

# A named release, or whatever perlbrew calls stable today.  The tarball is
# named after the release either way, so the directory under /opt/perl5 is too,
# and a guest that is rebuilt with another version keeps both.
if [ -n "$WANTED" ]; then
    perlbrew download "perl-$WANTED" || exit 1
    PERL_TARBALL="perl-$WANTED.tar.gz"
else
    perlbrew download stable || exit 1
    PERL_TARBALL=$(ls -1 /root/perl5/perlbrew/dists/ | tail -n1)
fi

[ -f "/root/perl5/perlbrew/dists/$PERL_TARBALL" ] || exit 1
NICE_PERL_NAME=$(echo $PERL_TARBALL | sed 's/\.tar\.gz$//' | sed 's/-//g')

if [ ! -f /opt/perl5/$NICE_PERL_NAME/bin/perl  ]; then
    rm -rf src
    tar --one-top-level=src --strip-components=1 -zxf ~/perl5/perlbrew/dists/$PERL_TARBALL
    cd src
    ./Configure -des -Dprefix=/opt/perl5/$NICE_PERL_NAME -Duseshrplib
    # One job for each processor on the guest, which gets two by default.  More
    # jobs than processors make a build of this size slower.
    JOBS=$(nproc 2>/dev/null || echo 2)
    make -j"$JOBS"
    make -j"$JOBS" install
fi

# What everything else installs into.  Written before cpanm, because
# cpan_install follows it from the next line onwards.  A relative target, so
# the link says the same thing on a guest and in a copy of /opt/perl5.
ln -sfn "$NICE_PERL_NAME" /opt/perl5/current

# Install cpanm with the CPAN client of the new perl, because nothing else can
# install it yet.  -T makes CPAN.pm skip the tests, and yes answers its first-run
# configuration.
#
# Install cpanm and nothing else this way.  CPAN.pm gives up on one failed fetch,
# and cpanm retries.
yes | "/opt/perl5/$NICE_PERL_NAME/bin/cpan" -T -i App::cpanminus || exit 1

# A distribution that needs one of these cannot install it for itself.
# cpan_install is the one thing on a guest that gets modules from CPAN.  This runs
# each time, so a module added here gets to a guest whose perl is already built.
"$WD/cpan_install" --notest install Module::Build Dist::Zilla || exit 1

# Where a person finds this perl.  The build does not use it, because make runs
# from an atd job under a non-interactive sh.  systemd and cron also read no
# shell init.  So everything that installs into this perl names it by path (see
# scripts/cpan_install).  This file is written again each run, so the perl that
# this build made is the one on the PATH.
cat > /etc/profile.d/perl.sh <<PROFILE
PATH="/opt/perl5/$NICE_PERL_NAME/bin:\$PATH"
PROFILE
chmod 0644 /etc/profile.d/perl.sh
