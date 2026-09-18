#!/bin/sh
# The ports of the packets UFW blocked on their way out.
#
# An outgoing packet did not arrive on an interface, so UFW logs it with an
# empty IN=.  A forwarded packet has both interfaces and is in neither this list
# nor the incoming one.  The log to read is the first argument, /var/log/syslog
# by default.
grep 'UFW BLOCK' "${1:-/var/log/syslog}" | grep -P '\bIN=(\s|$)' | grep -Po '(SPT=\d+|DPT=\d+)' | sort | uniq
