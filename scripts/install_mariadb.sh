#!/bin/bash

# Make sure that MariaDB is at exactly the requested version, then configure it
# and load its seed.
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
set -euo pipefail

# Not VERSION, because /etc/os-release defines VERSION, NAME and ID.
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

installed_version() { dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null || true; }

# cloud-init installs these at first boot, from the archive and the pin that
# Provisioner::Recipe::Ubuntu::mariadb names.  A guest provisioned again with
# another version gets the archive of that version the same way, and
# --allow-downgrades lets the install go down as well as up.
case "$(installed_version)" in
    *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $MARIADB_VERSION is already installed" ;;
    *)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
            mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat
        ;;
esac

# Another pin can win and a repository can hold a rebuild, so ask what is
# installed.
got=$(installed_version)
case "$got" in
    *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $got" ;;
    *) echo "install_mariadb.sh: installed mariadb-server $got, wanted $MARIADB_VERSION" >&2; exit 4 ;;
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
