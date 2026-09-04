#!/bin/bash

FSZ=$(stat --printf "%s" /root/.etcpasswd)
NEWSZ=$(stat --printf "%s" /etc/passwd)

if [ $FSZ != $NEWSZ ]
then
        echo "DANGER: New user detected, investigate /etc/passwd!"
        diff /root/.etcpasswd /etc/passwd
fi

cp /etc/passwd /root/.etcpasswd
