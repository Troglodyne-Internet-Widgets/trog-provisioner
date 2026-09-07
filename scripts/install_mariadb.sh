#!/bin/bash

# MariaDB, at exactly the version asked for, from MariaDB's own apt repository.
#
# Usage: install_mariadb.sh VERSION CONFIG SECURE_SQL SCHEMA SALVAGE
#
# CONFIG and SECURE_SQL are rendered by the recipe into the build directory and
# named relative to it, which is where the makefile runs this from.  SCHEMA is
# the dump, absolute, out of the domain's data directory.  SALVAGE is where the
# dumps taken off the guest this one replaces landed, which this only looks at
# to decide whether the schema is still wanted -- putting them back is
# mariadb-restore.sh's job, and the fragment runs it next.
#
# The exact version is the requirement, not a preference: binlogs restore only
# onto the version that wrote them, so "whatever the distribution ships" is not
# an option for a database this fleet expects to restore.
#
# A per-release repository exists only for the distributions that existed when
# that release was made -- 11.4.4 and 10.11.10 have noble, 10.11.7 does not --
# so this asks before it commits.
set -euo pipefail

# Not VERSION: /etc/os-release defines that, and NAME and ID besides.  Anything
# reading it has to keep its own names out of the way, which is also why the
# codename below is read in a subshell.
MARIADB_VERSION=$1
CONFIG=$2
SECURE_SQL=$3
SCHEMA=$4

# Defaulted rather than bare, alone among these: a makefile generated before
# this argument existed passes four, and the check below says what is missing
# rather than dying as an unbound variable three lines earlier.
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

    # curl -f catches an HTTP error; it does not catch a proxy answering 200
    # with a login page, which apt would report as a signature failure on every
    # source it has.
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

    # Above 1000 is what lets apt *downgrade* to it.  Ubuntu ships 10.11.14, so
    # a guest pinned to 10.11.10 would otherwise get the newer one and find out
    # at restore time.
    cat > /etc/apt/preferences.d/mariadb.pref <<'EOF'
Package: *
Pin: release o=MariaDB
Pin-Priority: 1001
EOF

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
        mariadb-server mariadb-client mariadb-backup libmariadb-dev libmariadb-dev-compat

    # A pin can be outvoted and a repository can hold a rebuild, so ask what is
    # actually installed rather than assuming the transaction meant what we did.
    local got
    got=$(installed_version)
    case "$got" in
        *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $got" ;;
        *) echo "install_mariadb.sh: installed mariadb-server $got, wanted $MARIADB_VERSION" >&2; exit 4 ;;
    esac
}

# Every provision runs this, and an apt transaction over the network is not free.
case "$(installed_version)" in
    *"$MARIADB_VERSION"*) echo "install_mariadb.sh: mariadb-server $MARIADB_VERSION is already installed" ;;
    *) add_repository ;;
esac

# Before the server is restarted, so it comes up reading our settings -- the
# schema below loads under the sql_mode and binlogging this configures rather
# than under the package's defaults.
install -m 0644 -o root -g root "$CONFIG" /etc/mysql/mariadb.conf.d/60-provisioner.cnf

systemctl enable mariadb
systemctl restart mariadb

# The socket, not a pidfile: it is what a client actually needs, and the pidfile
# appears before the server answers.
for _ in $(seq 30); do
    mariadb -e 'SELECT 1' >/dev/null 2>&1 && break
    echo "Waiting for mariadb to answer..."
    sleep 1
done
mariadb -e 'SELECT 1' >/dev/null 2>&1 || { echo "install_mariadb.sh: mariadb never came up" >&2; exit 5; }

# It holds the root password, so it goes whatever happens next -- including the
# run where securing has already been done and it is never read.
trap 'rm -f "$SECURE_SQL"' EXIT

# Keyed on the SQL rather than merely "has this ever run", so that changing
# root_pw re-runs it.  A bare marker would leave the database on the old
# password while every .my.cnf this recipe writes claims the new one, and the
# first thing to notice would be a backup that stopped working.
SECURED=/etc/mysql/.secured
WANT=$(sha256sum < "$SECURE_SQL" | cut -d' ' -f1)
if [ "$(cat "$SECURED" 2>/dev/null || true)" != "$WANT" ]; then
    mariadb < "$SECURE_SQL"
    printf '%s\n' "$WANT" > "$SECURED"
    chmod 0600 "$SECURED"
fi

# What goes into a server nobody has used yet, and nothing at all into one
# somebody has.
#
# The schema is a seed: the snapshot an operator put in the data directory for a
# domain that had no database of its own yet.  Loading it every provision is how
# a rebuilt guest came up holding that snapshot and nothing that had happened
# since, and how re-provisioning a live guest dropped and recreated whatever it
# names.  So it loads once, into a server with nothing in it, and only when
# there is no salvaged dump -- which is the same thing this guest had, only
# newer.
#
# mariadb-restore.sh applies the same rule to the same directory and the two
# have to agree about what is in it: a dump counts when it says it finished, by
# the `complete` the backup writes last.  If the seed loaded here while the
# restore stood aside, the guest would come up with the operator's old snapshot
# and none of what it was rebuilt to keep.
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
