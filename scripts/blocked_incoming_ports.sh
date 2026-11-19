#!/bin/sh
# The protocols and ports of the connections UFW blocked on their way in.
#
# An incoming packet has no output interface yet, so UFW logs it with an empty
# OUT=.  A forwarded packet has both interfaces and is in neither this list nor
# the outgoing one.  ufw_connection_attempts says which packets count.  The log
# to read is the first argument, /var/log/syslog by default.
grep -a 'UFW BLOCK' "${1:-/var/log/syslog}" | grep -a -P '\bOUT=(\s|$)' | "$(dirname "$0")/ufw_connection_attempts"
