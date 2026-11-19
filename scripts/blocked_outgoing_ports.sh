#!/bin/sh
# The protocols and ports of the connections UFW blocked on their way out.
#
# An outgoing packet did not arrive on an interface, so UFW logs it with an
# empty IN=.  A forwarded packet has both interfaces and is in neither this list
# nor the incoming one.  ufw_connection_attempts says which packets count.  The
# log to read is the first argument, /var/log/syslog by default.
grep -a 'UFW BLOCK' "${1:-/var/log/syslog}" | grep -a -P '\bIN=(\s|$)' | "$(dirname "$0")/ufw_connection_attempts"
