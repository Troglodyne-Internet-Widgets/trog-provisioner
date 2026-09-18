#!/bin/bash

# Let you know when a user who is not named on the command line becomes root.

# Only the test sets these, to point the script at files of its own.
STATE_DIR=${STATE_DIR:-/root}
if [ -z "$AUTHLOG" ]; then
    if [ -n "$(which rpm)" ]; then
        AUTHLOG=/var/log/secure
    else
        AUTHLOG=/var/log/auth.log
    fi
fi

oldIFS=$IFS;
IFS='|';
USER_EXEMPT_REGEX="$*"
IFS=$oldIFS;

# With no user named, every escalation is unexpected.
exempt() {
    if [ -n "$USER_EXEMPT_REGEX" ]; then
        grep -vP -- "$USER_EXEMPT_REGEX"
    else
        cat
    fi
}

SEEN="$STATE_DIR/escalations.log"

touch "$SEEN"
FSZ=$(stat --printf "%s" "$SEEN")
# Linux-PAM 1.4 and later write "for user root(uid=0) by", and older ones
# "for user root by".
grep -aE 'session opened for user root(\(uid=0\))? by' "$AUTHLOG" | exempt >> "$SEEN"
sort -u -o "$SEEN" "$SEEN"
NEWSZ=$(stat --printf "%s" "$SEEN")

if [ "$FSZ" != "$NEWSZ" ]
then
	echo "DANGER: Root escalation by unexpected user detected, investigate $AUTHLOG!"
	cat "$SEEN"
fi
