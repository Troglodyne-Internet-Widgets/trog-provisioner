#!/bin/bash

# Print a warning, which cron mails to you, when the OOM killer stops a process.

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    SYSLOG=/var/log/messages
else
    SYSLOG=/var/log/syslog
fi

touch /root/ooms.log
FSZ=$(stat --printf "%s" /root/ooms.log)
grep -i oom-killer $SYSLOG >> /root/ooms.log
echo "$(sort < /root/ooms.log | uniq)" > /root/ooms.log
NEWSZ=$(stat --printf "%s" /root/ooms.log)

if [ $FSZ != $NEWSZ ]
then
	echo "New OOM detected, investigate $SYSLOG:"
	cat /root/ooms.log
fi
