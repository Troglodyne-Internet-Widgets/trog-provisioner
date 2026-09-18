#!/bin/bash

# build_latest_perl.sh
#
# Build the latest perl into /opt/perl5 and give it cpanm, Module::Build and
# Dist::Zilla.  The target of the perl recipe installs its cpan_deps after this.
# scripts/cpan_install finds this perl as the newest under /opt/perl5.  A person
# finds it through profile.d.

# perlbrew fails under cloud-init without these.
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
    # One job for each processor on the guest, which gets two by default.  More
    # jobs than processors make a build of this size slower.
    JOBS=$(nproc 2>/dev/null || echo 2)
    make -j"$JOBS"
    make -j"$JOBS" install
fi

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
# scripts/cpan_install).  This file is written again each run, so the newest perl
# is on the PATH.
cat > /etc/profile.d/perl.sh <<PROFILE
PATH="/opt/perl5/$NICE_PERL_NAME/bin:\$PATH"
PROFILE
chmod 0644 /etc/profile.d/perl.sh
