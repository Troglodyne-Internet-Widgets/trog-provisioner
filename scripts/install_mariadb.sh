#!/bin/bash

# MariaDB, at exactly the version asked for, from MariaDB's own apt repository.
#
# The version pinning is not fussiness: binlogs restore only onto the exact
# version that wrote them, so "whatever the distribution ships" is not an
# option for a database this fleet expects to restore.
#
# This used to fetch the generic linux bintar from archive.mariadb.org, which
# pins exactly and costs something not obvious: that tarball is built against
# libaio, so InnoDB cannot use io_uring however the guest is configured -- the
# `ldd` has no liburing in it and mariadbd holds no io_uring descriptors.  It is
# also why this script used to have to symlink libaio.so.1t64 to libaio.so.1,
# the soname the bintar wants and noble renamed in the 64-bit time_t
# transition.
#
# archive.mariadb.org publishes a whole apt repository per release as well as
# the bintar, and those are Debian-style builds: mariadb-server-core there
# depends on liburing2.  So the same exact pinning, without giving up io_uring
# and without hand-rolling a layout under /opt.
#
# The catch, and it is the reason this checks before it commits: a per-release
# repository only exists for distributions that existed when that release was
# made.  11.4.4 and 10.11.10 have noble; 10.11.7 and anything older do not.
set -euo pipefail

# MARIADB_VERSION, not VERSION.  /etc/os-release defines VERSION -- and NAME,
# and ID, and half a dozen others -- so sourcing it into this scope renamed the
# release we were asked for to "24.04.4 LTS (Noble Numbat)" and sent the whole
# thing looking for a repository under that.  Read in a subshell for the same
# reason: nothing here wants os-release's idea of any of its variables except
# the one it is asked for.
MARIADB_VERSION=$1
SCHEMA=$2

for arg in MARIADB_VERSION SCHEMA; do
    [ -n "${!arg:-}" ] || { echo "install_mariadb.sh: $arg is empty; refusing to guess" >&2; exit 2; }
done

CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
[ -n "$CODENAME" ] || { echo "install_mariadb.sh: no VERSION_CODENAME in /etc/os-release" >&2; exit 2; }

REPO="https://archive.mariadb.org/mariadb-$MARIADB_VERSION/repo/ubuntu"

# Ask before adding it, so a version with no repository for this distribution
# fails here saying which ones it does have, rather than as a 404 out of
# `apt-get update` three steps later.
if ! curl -fsI "$REPO/dists/$CODENAME/Release" >/dev/null 2>&1; then
    echo "install_mariadb.sh: mariadb $MARIADB_VERSION has no apt repository for $CODENAME." >&2
    echo "  MariaDB publishes one per release per distribution, and only for the" >&2
    echo "  distributions that existed when the release was made." >&2
    echo "  $MARIADB_VERSION has: $(curl -fsSL "$REPO/dists/" 2>/dev/null | grep -oE 'href="[a-z]+/"' | sed 's/href="//;s|/"||' | tr '\n' ' ')" >&2
    exit 3
fi

install -d -m 0755 /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/mariadb.pgp https://mariadb.org/mariadb_release_signing_key.pgp

cat > /etc/apt/sources.list.d/mariadb.sources <<EOF
Types: deb
URIs: $REPO
Suites: $CODENAME
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/mariadb.pgp
EOF

# Above 1000, which is what lets apt *downgrade* to it.  Ubuntu ships 10.11.14;
# a guest pinned to 10.11.10 wants the older one, and at any priority below 1001
# apt would quietly install the newer and the binlogs would not restore.
cat > /etc/apt/preferences.d/mariadb.pref <<'EOF'
Package: *
Pin: release o=MariaDB
Pin-Priority: 1001
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat

# What we asked for is not always what we got: a pin can be outvoted, a repo can
# hold a rebuild.  Say so rather than discovering it at restore time.
INSTALLED=$(dpkg-query -W -f='${Version}' mariadb-server)
case "$INSTALLED" in
    *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $INSTALLED" ;;
    *) echo "install_mariadb.sh: installed mariadb-server $INSTALLED, wanted $MARIADB_VERSION" >&2; exit 4 ;;
esac

systemctl enable mariadb
systemctl start mariadb

# Root authenticates over the unix socket, which is how the package leaves it and
# how everything here connects.  Wait for the socket rather than for a pidfile:
# it is the thing a client actually needs.
for _ in $(seq 30); do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
    echo "Waiting for mariadb to answer..."
    sleep 1
done
mariadb -e 'SELECT 1' >/dev/null 2>&1 || { echo "install_mariadb.sh: mariadb never came up" >&2; exit 5; }

mariadb < "$SCHEMA"
