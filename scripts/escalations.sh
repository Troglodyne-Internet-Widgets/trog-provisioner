#!/bin/bash

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    AUTHLOG=/var/log/secure
else
    AUTHLOG=/var/log/auth.log
fi

oldIFS=$IFS;
IFS='|';
USER_EXEMPT_REGEX="$*"
IFS=$oldIFS;

touch /root/escalations.log
FSZ=$(stat --printf "%s" /root/escalations.log)
grep 'session opened for user root by' $AUTHLOG | grep -vP $USER_EXEMPT_REGEX >> /root/escalations.log
echo "$(sort < /root/escalations.log | uniq)" > /root/escalations.log
NEWSZ=$(stat --printf "%s" /root/escalations.log)

if [ $FSZ != $NEWSZ ]
then
	echo "DANGER: Root escalation by unexpected user detected, investigate $AUTHLOG!"
	cat /root/escalations.log
fi
