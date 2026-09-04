grep 'UFW BLOCK' /var/log/syslog | grep -P 'IN=\S+' | grep -Po '(SPT=\d+|DPT=\d+)' | sort | uniq
