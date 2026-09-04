#!/bin/bash

# HA HA HA you think you can use packaged software for your DB.
# You would be wrong, as binlogs can only be restored on *the exact same version*.
# Welcome to hell.

CLIENT=$1
VERSION=$2
SCHEMA=$3

# An empty argument is no argument at all once the shell has split the command
# line, so a template variable that rendered empty silently shifted these along
# -- $CLIENT held the version, $VERSION held the path to the dump, and the
# download asked archive.mariadb.org for a URL with a filesystem path in the
# middle of it.  Say so instead.
for arg in CLIENT VERSION SCHEMA; do
    [ -n "${!arg}" ] || { echo "install_mariadb.sh: $arg is empty; refusing to guess" >&2; exit 2; }
done

wait_for_mysql() {
    retry=30
    ctr=0
    until pgrep -F /opt/mysql/pidfile &> /dev/null
    do
        [ $ctr -eq $retry ] && echo "Server didn't come up within $retry seconds" && exit 1
        echo "Waiting for mysql server to come live (try $ctr)..."
        sleep 1
        let "ctr+=1"
    done
}

wait_for_no_mysql() {
    retry=30
    ctr=0
    until ! pgrep -F /opt/mysql/pidfile &> /dev/null
    do
        [ $ctr -eq $retry ] && echo "Server didn't die within $retry seconds" && exit 1
        echo "Waiting for mysql server to shutdown (try $ctr)..."
        sleep 1
        let "ctr+=1"
    done
}


if [ ! -f /opt/mysql/bin/mariadbd ]; then
    ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
    mkdir -p /opt/mysql
    # -f: without it curl saves the error page on a 404 and the only sign is
    # tar saying "not in gzip format" several lines later.
    curl -fso /tmp/mysql.tar.gz -- https://archive.mariadb.org/mariadb-$VERSION/bintar-linux-systemd-x86_64/mariadb-$VERSION-linux-systemd-x86_64.tar.gz \
        || { echo "install_mariadb.sh: could not download mariadb $VERSION" >&2; exit 3; }
    stat /tmp/mysql.tar.gz
    stat /opt/mysql/
    echo "curl -so /tmp/mysql.tar.gz -- https://archive.mariadb.org/mariadb-$VERSION/bintar-linux-systemd-x86_64/mariadb-$VERSION-linux-systemd-x86_64.tar.gz"
    tar --strip-components=1 -C /opt/mysql/ -zxf /tmp/mysql.tar.gz
    rm /tmp/mysql.tar.gz

    # Time to make a datadir & launch this sucker
    mkdir -p /opt/mysql/data
    mkdir -p /opt/mysql/binlogs
    mkdir -p /opt/mysql/logs
    chown -R mysql:$CLIENT /opt/mysql

    # Initialize the DB
    /opt/mysql/scripts/mariadb-install-db --defaults-file=/opt/mysql/my.cnf
    ln -s /opt/mysql/mariadb.service /usr/lib/systemd/system/mariadb.service
    systemctl enable mariadb
    systemctl start  mariadb

    wait_for_mysql

    rm -rf /tmp/mysql/$CLIENT
fi

# Install the schema for the client
mysql --defaults-file=/opt/mariadb/my.cnf -- < $SCHEMA
wait_for_mysql
