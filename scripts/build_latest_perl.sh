#!/bin/bash

# build_latest_perl.sh
#
# Build the latest perl into /opt/perl5, give it its cpanm, and link both where
# scripts/cpan_install looks for them.  What goes into it is the perl recipe's
# cpan_deps, installed by that recipe's target after this; the tools are linked
# into an account's bin by scripts/link_perl_tools, after those.

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

# The links scripts/cpan_install finds this perl by, which everything installed
# into it goes through.  The rest of them are scripts/link_perl_tools', run
# after those installs rather than before: a link is only made for a tool that
# is there.
mkdir -p /root/bin
for tool in perl cpanm; do
    [ -e "/opt/perl5/$NICE_PERL_NAME/bin/$tool" ] || continue
    [ -L "/root/bin/$tool" ] && continue
    ln -s "/opt/perl5/$NICE_PERL_NAME/bin/$tool" "/root/bin/$tool"
done
