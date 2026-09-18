#!/bin/bash

# Install MariaDB at exactly the requested version, from the apt repository of
# MariaDB.
#
# Usage: install_mariadb.sh VERSION CONFIG SECURE_SQL SCHEMA SALVAGE
#
# The recipe renders CONFIG and SECURE_SQL into the build directory.  Their
# paths are relative to it, because the makefile runs this script from there.
# SCHEMA is the absolute path of the dump in the data directory of the domain.
# SALVAGE is the directory that holds the dumps taken from the guest that this
# one replaces.  This script reads it only to decide if it loads SCHEMA.
# mariadb-restore.sh restores those dumps, and the fragment runs it next.
#
# The exact version is necessary.  Binlogs restore only onto the version that
# wrote them, so the version that the distribution ships is not sufficient.
#
# MariaDB has a repository for a release only for the distributions that existed
# when that release was made.  For example, 11.4.4 and 10.11.10 have noble, but
# 10.11.7 does not.  So this script asks before it adds the repository.
set -euo pipefail

# Not VERSION, because /etc/os-release defines VERSION, NAME and ID.  For the
# same reason, a subshell reads the codename below.
MARIADB_VERSION=$1
CONFIG=$2
SECURE_SQL=$3
SCHEMA=$4

# Defaulted, so that a makefile that passes four arguments gets the message
# below and not an unbound-variable error from set -u.
SALVAGE=${5:-}

for arg in MARIADB_VERSION CONFIG SECURE_SQL SCHEMA SALVAGE; do
    [ -n "${!arg:-}" ] || { echo "install_mariadb.sh: $arg is empty; refusing to guess" >&2; exit 2; }
done

CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
[ -n "$CODENAME" ] || { echo "install_mariadb.sh: no VERSION_CODENAME in /etc/os-release" >&2; exit 2; }

REPO="https://archive.mariadb.org/mariadb-$MARIADB_VERSION/repo/ubuntu"

installed_version() { dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null || true; }

add_repository() {
    if ! curl -fsI "$REPO/dists/$CODENAME/Release" >/dev/null 2>&1; then
        echo "install_mariadb.sh: mariadb $MARIADB_VERSION has no apt repository for $CODENAME." >&2
        echo "  MariaDB publishes one per release per distribution, and only for the" >&2
        echo "  distributions that existed when the release was made." >&2
        echo "  $MARIADB_VERSION has: $(curl -fsSL "$REPO/dists/" 2>/dev/null | grep -oE 'href="[a-z]+/"' | sed 's/href="//;s|/"||' | tr '\n' ' ')" >&2
        exit 3
    fi

    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL -o /etc/apt/keyrings/mariadb.pgp https://mariadb.org/mariadb_release_signing_key.pgp

    # curl -f catches an HTTP error, but not a proxy that answers 200 with a
    # login page.  apt then reports a signature failure on every source.
    gpg --show-keys /etc/apt/keyrings/mariadb.pgp >/dev/null 2>&1 \
        || { echo "install_mariadb.sh: what came back from mariadb.org is not a PGP key" >&2; exit 3; }

    cat > /etc/apt/sources.list.d/mariadb.sources <<EOF
Types: deb
URIs: $REPO
Suites: $CODENAME
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/mariadb.pgp
EOF

    # A priority above 1000 lets apt downgrade to this repository.  Ubuntu ships
    # 10.11.14, so without it a guest pinned to 10.11.10 gets the newer version.
    cat > /etc/apt/preferences.d/mariadb.pref <<'EOF'
Package: *
Pin: release o=MariaDB
Pin-Priority: 1001
EOF

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
        mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat

    # Another pin can win and a repository can hold a rebuild, so ask what is
    # installed.
    local got
    got=$(installed_version)
    case "$got" in
        *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $got" ;;
        *) echo "install_mariadb.sh: installed mariadb-server $got, wanted $MARIADB_VERSION" >&2; exit 4 ;;
    esac
}

# Every provision runs this, so skip apt when the version is already installed.
case "$(installed_version)" in
    *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $MARIADB_VERSION is already installed" ;;
    *) add_repository ;;
esac

# Before the restart, so that the schema below loads under the sql_mode and
# binlog settings of this file, not the defaults of the package.
install -m 0644 -o root -g root "$CONFIG" /etc/mysql/mariadb.conf.d/60-provisioner.cnf

systemctl enable mariadb
systemctl restart mariadb

# Ask through the socket, not a pidfile, because the pidfile appears before the
# server answers.
for _ in $(seq 30); do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
    echo "Waiting for mariadb to answer..."
    sleep 1
done
mariadb -e 'SELECT 1' >/dev/null 2>&1 || { echo "install_mariadb.sh: mariadb never came up" >&2; exit 5; }

# SECURE_SQL holds the root password, so remove it on every exit, including a
# run that does not read it.
trap 'rm -f "$SECURE_SQL"' EXIT

# The marker holds a hash of the SQL, so a change to root_pw runs it again.
# Otherwise the database keeps the old password while every .my.cnf that this
# recipe writes has the new one.
SECURED=/etc/mysql/.secured
WANT=$(sha256sum < "$SECURE_SQL" | cut -d' ' -f1)
if [ "$(cat "$SECURED" 2>/dev/null || true)" != "$WANT" ]; then
    mariadb < "$SECURE_SQL"
    printf '%s\n' "$WANT" > "$SECURED"
    chmod 0600 "$SECURED"
fi

# The schema is a seed.  It is a snapshot that an operator put in the data
# directory for a domain that had no database yet.  It loads only into a server
# that has no user databases, and only if SALVAGE holds no finished dump.  A
# salvaged dump holds the same databases as the seed, with newer data.
#
# mariadb-restore.sh applies the same rule to the same directory, and the two
# must agree.  A dump counts as finished when it contains the `complete` file
# that the backup writes last.
user_databases() {
    mariadb -sN -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','sys','mysql')"
}

if [ -n "$(user_databases)" ]; then
    echo "install_mariadb.sh: this server already has databases; $SCHEMA is a seed and is not loaded over them"
elif [ -n "$(find "$SALVAGE" -mindepth 2 -maxdepth 2 -name complete -print -quit 2>/dev/null)" ]; then
    echo "install_mariadb.sh: $SALVAGE holds a finished dump, so the seed in $SCHEMA stands aside for mariadb-restore.sh"
else
    mariadb < "$SCHEMA"
fi
