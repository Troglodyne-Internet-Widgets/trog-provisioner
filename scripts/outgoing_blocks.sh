#!/bin/bash

# Let you know when something outblocked

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    SYSLOG=/var/log/messages
else
    SYSLOG=/var/log/syslog
fi

touch /root/outblocked.log
touch /root/new-outblocked.log
mv /root/new-outblocked.log /root/outblocked.log
FSZ=$(stat --printf "%s" /root/outblocked.log)
grep 'UFW BLOCK' /var/log/syslog | grep -P 'OUT=\S+' | grep -Po '(SPT=\d+|DPT=\d+)' >> /root/new-outblocked.log
echo "$(sort < /root/new-outblocked.log | uniq)" > /root/new-outblocked.log
NEWSZ=$(stat --printf "%s" /root/new-outblocked.log)

if [ $FSZ != $NEWSZ ]
then
	echo "DANGER: New Outgoing port block detected, investigate $SYSLOG!"
	diff /root/outblocked.log /root/new-outblocked.log
fi
