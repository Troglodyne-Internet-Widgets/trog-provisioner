#!/bin/bash

# Idea here is to mail you when something starts espamming the log
IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    SYSLOG=/var/log/messages
else
    SYSLOG=/var/log/syslog
fi

touch /root/logdrops.log
FSZ=$(stat --printf "%s" /root/logdrops.log)
grep 'drop messages due to rate-limiting' $SYSLOG >> /root/logdrops.log
echo "$(sort < /root/logdrops.log | uniq)" > /root/logdrops.log
NEWSZ=$(stat --printf "%s" /root/logdrops.log)

if [ $FSZ != $NEWSZ ]
then
	echo "DANGER: rsyslog messages being dropped, investigate $SYSLOG!"
	cat /root/logdrops.log
fi
