#!/bin/bash

CLIENT=$1

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
    yes | /opt/perl5/$NICE_PERL_NAME/bin/cpan App::cpanminus Test2 Devel::NYTProf starman Perl::Critic Perl::Tidy
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

# Build some symlinks to the perl for use by other? setup scripts
mkdir -p $CLIENT_HOMEDIR/bin
mkdir -p /root/bin
[ -L $CLIENT_HOMEDIR/bin/perl  ]   || ln -s /opt/perl5/$NICE_PERL_NAME/bin/perl  $CLIENT_HOMEDIR/bin/perl
[ -L $CLIENT_HOMEDIR/bin/prove  ]   || ln -s /opt/perl5/$NICE_PERL_NAME/bin/prove  $CLIENT_HOMEDIR/bin/prove
[ -L $CLIENT_HOMEDIR/bin/yath  ]   || ln -s /opt/perl5/$NICE_PERL_NAME/bin/yath  $CLIENT_HOMEDIR/bin/yath
[ -L $CLIENT_HOMEDIR/bin/dzil  ]   || ln -s /opt/perl5/$NICE_PERL_NAME/bin/dzil  $CLIENT_HOMEDIR/bin/dzil
[ -L $CLIENT_HOMEDIR/bin/cpanm ]   || ln -s /opt/perl5/$NICE_PERL_NAME/bin/cpanm $CLIENT_HOMEDIR/bin/cpanm
[ -L $CLIENT_HOMEDIR/bin/starman ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/starman $CLIENT_HOMEDIR/bin/starman
[ -L $CLIENT_HOMEDIR/bin/perlcritic ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/perlcritic $CLIENT_HOMEDIR/bin/perlcritic
[ -L $CLIENT_HOMEDIR/bin/perltidy ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/perltidy $CLIENT_HOMEDIR/bin/perltidy
[ -L $CLIENT_HOMEDIR/bin/nytprofmerge ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/nytprofmerge $CLIENT_HOMEDIR/bin/nytprofmerge
[ -L $CLIENT_HOMEDIR/bin/nytprofhtml ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/nytprofhtml $CLIENT_HOMEDIR/bin/nytprofhtml
[ -L /root/bin/perl  ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/perl  /root/bin/perl
[ -L /root/bin/cpanm ] || ln -s /opt/perl5/$NICE_PERL_NAME/bin/cpanm /root/bin/cpanm

