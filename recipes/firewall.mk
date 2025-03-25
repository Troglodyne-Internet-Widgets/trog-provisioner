.PHONY: disable-stub-resolver
disable-stub-resolver:
ifneq (exists, $(shell test -f /etc/systemd/resolved.conf.d/10-disable-stub-resolver.conf && echo 'exists'))
	sudo mkdir /etc/systemd/resolved.conf.d/; /bin/true
	sudo cp dns/10-disable-stub-resolver.conf /etc/systemd/resolved.conf.d/
	sudo chown -R systemd-resolve:systemd-resolve /etc/systemd/resolved.conf.d/
	sudo chmod 0660 /etc/systemd/resolved.conf.d/10-disable-stub-resolver.conf
	sudo systemctl restart systemd-resolved
endif

.PHONY: configure-domain
configure-domain:
	cp dns/tcms.tmpl dns/tcms.conf
	sed -i 's#__DIR__#$(shell pwd)#g' dns/tcms.conf
	sed -i 's#__DOMAIN__#$(SERVER_NAME)#g' dns/tcms.conf
	[[ -e /etc/powerdns/pdns.d/$(SERVER_NAME).conf ]] && sudo rm /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo cp dns/tcms.conf /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo chmod 0755 /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	# Build the zone database and initialize the zone for our domain
	rm dns/zones.db; /bin/true
	sqlite3 dns/zones.db < /usr/share/pdns-backend-sqlite3/schema/schema.sqlite3.sql
	bin/build_zone > dns/default.zone
	zone2sql --gsqlite --zone=dns/default.zone --zone-name=$(SERVER_NAME) > dns/default.zone.sql
	sqlite3 dns/zones.db < dns/default.zone.sql
	# Bind mount our dns/ folder so that pdns can see it in chroot
	sudo mkdir /var/spool/powerdns/$(SERVER_NAME); /bin/true
	sudo chown pdns:pdns /var/spool/powerdns/$(SERVER_NAME); /bin/true
	sudo cp /etc/fstab /tmp/fstab.new
	sudo chown $(USER) /tmp/fstab.new
	echo "$(shell pwd)/dns /var/spool/powerdns/$(SERVER_NAME) none defaults,bind 0 0" >> /tmp/fstab.new
	sort < /tmp/fstab.new | uniq | grep -o '^[^#]*' > /tmp/fstab.newer
	sudo chown root:root /tmp/fstab.newer
	sudo mv /etc/fstab /etc/fstab.bak
	sudo mv /tmp/fstab.newer /etc/fstab
	sudo mount /var/spool/powerdns/$(SERVER_NAME)
	sudo chown $(USER_NAME):pdns dns/
	sudo chown $(USER_NAME):pdns dns/zones.db

.PHONY: dns
dns: disable-stub-resolver
	# Don't need no bind. By default, just have the DNS server do nothing.
	[[ -e /etc/powerdns/pdns.d/bind.conf ]] && sudo rm /etc/powerdns/pdns.d/bind.conf; /bin/true
	# Fix broken service configuration
	sudo dns/configure_pdns
	sudo mkdir -p /var/spool/powerdns/run/pdns/; /bin/true
	sudo chown -R pdns:pdns /var/spool/powerdns/run
	sudo cp dns/10-powerdns.conf /etc/rsyslog.d/10-powerdns.conf
	sudo systemctl daemon-reload
	sudo systemctl restart rsyslog
	sudo systemctl enable pdns
	sudo systemctl start pdns
