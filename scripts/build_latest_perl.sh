#!/bin/bash

# build_latest_perl.sh
#
# Build the latest perl into /opt/perl5 and give it cpanm, Module::Build and
# Dist::Zilla.  What else goes into it is the perl recipe's cpan_deps, installed
# by that recipe's target after this; scripts/cpan_install finds this perl as
# the newest under /opt/perl5, and a person finds it through profile.d.

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
fi

# Its cpanm, from the new perl's own CPAN client, since nothing else can install
# one yet: -T so CPAN.pm skips the suite, and yes to answer its first-run
# configuration.
#
# cpanm and nothing else.  Measured on a guest: CPAN.pm two hundred
# distributions into Dist::Zilla's tree lost a single fetch to "SSL connection
# failed for cpan.org: SSL wants a read first", gave up, and took the build with
# it.  cpanm is what every other install on a guest goes through, and it retries.
yes | "/opt/perl5/$NICE_PERL_NAME/bin/cpan" -T -i App::cpanminus || exit 1

# What a distribution needing either cannot install for itself, through the one
# thing on a guest that reaches CPAN.  Every run rather than only the first, so a
# module added here reaches a guest whose perl is already built.
"$WD/cpan_install" --notest install Module::Build Dist::Zilla || exit 1

# Where a person finds this perl.  Not where the build finds it: make runs its
# recipe lines under a non-interactive sh out of an atd job, and systemd and
# cron read no shell init either, so everything that installs into this perl
# names it by path -- see scripts/cpan_install.  Rewritten every run, so a perl
# built since is the one on the PATH.
cat > /etc/profile.d/perl.sh <<PROFILE
PATH="/opt/perl5/$NICE_PERL_NAME/bin:\$PATH"
PROFILE
chmod 0644 /etc/profile.d/perl.sh
