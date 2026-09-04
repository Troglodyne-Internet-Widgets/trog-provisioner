#!/bin/bash

# This backup script runs as root on the remote.  As such, you'll want to authorize the key via a mechanism similar to that done in the 'backup' target.

REMOTE=$1
shift
BASEDIR=$1
shift
KEYFILE=$1
shift
PORT=$1
shift
TARGETS="$@"
DATE=$(date -I)
YESTERDAY=$(date -I --date '-1 day')
BACKUPDIR=/$BASEDIR/$REMOTE

# Semaphore
[[ -f /root/backup_in_progress_$REMOTE ]] && logger --stderr "Another backup in progress, exiting" && exit 1;

touch /root/backup_in_progress_$REMOTE


# Snapshot the host.
logger --stderr "Backing up $REMOTE..."
logger --stderr "Using $KEYFILE against $REMOTE to backup $TARGETS into $BASEDIR"

for TARGET in $@; do

    LINKDIR="$BACKUPDIR/$YESTERDAY/$TARGET"
    mkdir -p $LINKDIR

    DESTDIR="$BACKUPDIR/$DATE/$TARGET"
    mkdir -p $DESTDIR

    logger --stderr "Copying $TARGET data to $DESTDIR with hardlinking to $LINKDIR..."
    logger --stderr "rsync -a --delete --fuzzy --fuzzy -e \"ssh -i $KEYFILE -p$PORT -o 'StrictHostKeyChecking no'\" rsync://root@$REMOTE/$TARGET --link-dest $LINKDIR $DESTDIR"
    rsync -a --delete --fuzzy --fuzzy -e "ssh -i $KEYFILE -p$PORT -o 'StrictHostKeyChecking no'" rsync://root@$REMOTE/$TARGET --link-dest $LINKDIR $DESTDIR
    CHANGED_FILES=$(find $DESTDIR -type f -links 1 | wc -l)
    logger --stderr "$CHANGED_FILES changed files in $TARGET"
    USAGE=$(df -h $BASEDIR | awk '{print $5}' | tail -n1)
    logger --stderr "Disk usage at $USAGE"

done

logger --stderr "Done."

rm /root/backup_in_progress_$REMOTE
