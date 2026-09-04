#!/bin/sh

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    SA1=/usr/lib64/sa/sa1
else
    SA1=/usr/lib/sysstat/sa1
fi

$SA1 1 1 -S DISK
