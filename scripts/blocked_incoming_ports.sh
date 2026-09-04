grep 'UFW BLOCK' /var/log/syslog | grep -P 'OUT=\S+' | grep -Po '(SPT=\d+|DPT=\d+)' | sort | uniq
