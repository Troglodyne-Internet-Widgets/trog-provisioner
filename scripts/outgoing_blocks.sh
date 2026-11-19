#!/bin/bash

# Print a warning, which cron mails to you, when ufw blocks an outgoing
# connection to a port that it did not block before.  A forwarded packet has an
# output interface too, so a blocked forward counts.  ufw_connection_attempts
# says which packets count.

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
grep -a 'UFW BLOCK' "$SYSLOG" | grep -a -P 'OUT=\S+' | "$(dirname "$0")/ufw_connection_attempts" > "$NOW"

# A port in this run's list that the last run did not have.  A size
# comparison misses a new port when rotation takes an old one out of the log.
NEW_BLOCKS=$(comm -13 "$SEEN" "$NOW")
if [ -n "$NEW_BLOCKS" ]
then
	echo "DANGER: New Outgoing port block detected, investigate $SYSLOG!"
	echo "$NEW_BLOCKS"
fi
