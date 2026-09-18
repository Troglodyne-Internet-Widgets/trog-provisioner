#!/bin/bash

BACKUP_HOST=$1
BASE_DIR=$2

CUTOFF=$(date -d"-1 months" +%s)

declare DIRS=("$BASE_DIR/$BACKUP_HOST");

for dir in "${DIRS[@]}"
do
    logger --stderr "Pruning $dir..."
    for subdir in "$dir"/*
    do
        # An empty directory leaves the glob unexpanded.
        [ -e "$subdir" ] || continue

        # backup.sh names each backup by its date.  Anything else is not ours
        # to prune.
        CUR_TIME=$(date -d"$(basename "$subdir")" +%s 2>/dev/null) || continue
        if [ "$CUR_TIME" -lt "$CUTOFF" ]
        then
            logger --stderr "Deleting $subdir"
            rm -rf -- "$subdir"
        fi
    done
done
