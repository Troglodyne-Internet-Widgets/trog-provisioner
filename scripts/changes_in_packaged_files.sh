#!/bin/bash

# Let you know when a file managed by the packager changes

IS_RPM=$(which rpm)

if [ ! -z $IS_RPM ]
then
    CHECKFILE=/root/rpmcheck.log
    DIFFLOG=/root/rpmdiffs.log
    rpm -qa 2>&1 | xargs rpm -V &> $CHECKFILE
else
    CHECKFILE=/root/debcheck.log
    DIFFLOG=/root/debdiffs.log
    debsums -c 2>&1 | sort -u &> $CHECKFILE
fi

touch $CHECKFILE.old
diff $CHECKFILE.old $CHECKFILE >> $DIFFLOG
mv $CHECKFILE $CHECKFILE.old

FSZ=$(stat --printf "%s" $DIFFLOG)
echo -n "$(sort < $DIFFLOG | uniq)" > $DIFFLOG
NEWSZ=$(stat --printf "%s" $DIFFLOG)

if [ $FSZ != $NEWSZ ]
then
    echo "DANGER: New changes to OS managed files!  Check $DIFFLOG and the audit logs!"
    if [ ! -z $IS_RPM ]
    then
        echo "To examine particular changes do the following:"
        echo "cd /tmp && mkdir rpmcheck"
        echo "yum whatprovides \$FILE"
        echo "yumdownloader \$PACKAGE_FROM_ABOVE_OUTPUT"
        echo "rpm2cpio \$RPM_SO_DOWNLOADED  | cpio -idmv"
        echo "diff \$FILE_WITHOUT_LEADING_SLASH \$FILE"
        echo
        echo "To list packages to reinstall, do the following:"
        echo "rpm -qa | xargs rpm -V | xargs yum whatprovides"
    else
        echo "To list packages to reinstall, do the following:"
        echo "debsums -c | xargs -rd '\\n' -- dpkg -S | cut -d : -f 1 | sort -u"
    fi
    cat $DIFFLOG
    echo
fi

