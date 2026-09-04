#!/bin/bash

BACKUP_HOST=$1
BASE_DIR=$2

CUTOFF=$(date -d"-1 months" +%s)

declare DIRS=("$BASE_DIR/$BACKUP_HOST");

for dir in "${DIRS[@]}"
do
    logger --stderr "Pruning $dir..."
    for subdir in $dir/*
    do
        CUR_DATE=$(basename $subdir)
        CUR_TIME=$(date -d"$CUR_DATE" +%s)
        if [ $CUR_TIME -lt $CUTOFF ]
        then
            logger --stderr "Deleting $subdir"
            rm -rf $subdir
        fi
    done
done
