#!/bin/bash

# Report a new segfault in the system log.

# Only the test sets these, to point the script at files of its own.
STATE_DIR=${STATE_DIR:-/root}
if [ -z "$SYSLOG" ]; then
    if [ -n "$(which rpm)" ]; then
        SYSLOG=/var/log/messages
    else
        SYSLOG=/var/log/syslog
    fi
fi

SEEN="$STATE_DIR/segfaults.log"
NOW="$STATE_DIR/new-segfaults.log"

touch "$NOW"
mv "$NOW" "$SEEN"

# -a, because a crash can leave NUL bytes in the log, and grep then stops
# printing lines for what it takes to be a binary file.
grep -ai 'segfault' "$SYSLOG" 2>/dev/null | grep -v 'segfaults.sh' | sort -u > "$NOW"

# A line in this run's list that the last run did not have.  A size
# comparison misses a new segfault when rotation takes an old line of the
# same length out of the log.
NEW_SEGFAULTS=$(comm -13 "$SEEN" "$NOW")
if [ -n "$NEW_SEGFAULTS" ]
then
	echo "DANGER: New Segmentation Fault detected, investigate $SYSLOG!"
	echo "$NEW_SEGFAULTS"
fi
