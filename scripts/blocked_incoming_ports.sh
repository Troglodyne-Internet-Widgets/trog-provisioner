#!/bin/sh
# The ports of the packets UFW blocked on their way in.
#
# An incoming packet has no output interface yet, so UFW logs it with an empty
# OUT=.  A forwarded packet has both interfaces and is in neither this list nor
# the outgoing one.  The log to read is the first argument, /var/log/syslog by
# default.
grep 'UFW BLOCK' "${1:-/var/log/syslog}" | grep -P '\bOUT=(\s|$)' | grep -Po '(SPT=\d+|DPT=\d+)' | sort | uniq
