#!/bin/bash

# Let you know when something segfaults

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    SYSLOG=/var/log/messages
else
    SYSLOG=/var/log/syslog
fi

touch /root/segfaults.log
touch /root/new-segfaults.log
mv /root/new-segfaults.log /root/segfaults.log
FSZ=$(stat --printf "%s" /root/segfaults.log)
grep -i 'segfault' $SYSLOG 2>/dev/null | grep -v 'segfaults.sh' >> /root/new-segfaults.log
echo "$(sort < /root/new-segfaults.log | uniq)" > /root/new-segfaults.log
NEWSZ=$(stat --printf "%s" /root/new-segfaults.log)

if [ $FSZ != $NEWSZ ]
then
	echo "DANGER: New Segmentation Fault detected, investigate $SYSLOG!"
	diff /root/segfaults.log /root/new-segfaults.log
fi
