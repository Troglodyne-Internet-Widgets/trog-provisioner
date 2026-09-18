#!/bin/bash

# Print a warning, which cron mails to you, when ufw blocks an outgoing port
# that it did not block before.

# Only the test sets these, to point the script at files of its own.
STATE_DIR=${STATE_DIR:-/root}
if [ -z "$SYSLOG" ]; then
    if [ -n "$(which rpm)" ]; then
        SYSLOG=/var/log/messages
    else
        SYSLOG=/var/log/syslog
    fi
fi

SEEN="$STATE_DIR/outblocked.log"
NOW="$STATE_DIR/new-outblocked.log"

touch "$NOW"
mv "$NOW" "$SEEN"

# -a, because a crash can leave NUL bytes in the log, and grep then stops
# printing lines for what it takes to be a binary file.
grep -a 'UFW BLOCK' "$SYSLOG" | grep -P 'OUT=\S+' | grep -Po '(SPT=\d+|DPT=\d+)' | sort -u > "$NOW"

# A port in this run's list that the last run did not have.  A size
# comparison misses a new port when rotation takes an old one out of the log.
NEW_BLOCKS=$(comm -13 "$SEEN" "$NOW")
if [ -n "$NEW_BLOCKS" ]
then
	echo "DANGER: New Outgoing port block detected, investigate $SYSLOG!"
	echo "$NEW_BLOCKS"
fi
