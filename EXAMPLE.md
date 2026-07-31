# Example Usage

Herein lie some examples of provisioners usage.

## Deploy a tCMS site

With the following data in the noted files/dirs, you should be able to provision
a tCMS site hosted by tPSGI correctly at test.test.test:

### ipmap.cfg:

```
[global]
tld=test.test                # Obviously change to a domain you control
ip=127.0.0.0                 # You will want to set this to the actual IP of your HV
basedir=/opt/domains         # Change depending on your disk layout
transfer_user=me             # User which is going to run trog-provisioner
admin_user=you               # User which will be admin on the guests
admin_key=gh:teodesian       # How to get the key for said admin via ssh-import-id
admin_email=test@test.test   # MAILTO for most crons
admin_gecos=Testy McTester   # Who to blame
gateway=1.1.1.1              # Gateway to setup on the guests
resolvers=127.0.0.1          # Comma-separated list of resolvers to use on guests
bridge_devname=ens4          # device name to setup a static IP on
dhcp_devname=ens3            # device name to setup dhcp IP on
[ip_pool]
addresses=                   # Both of these are comma separated lists of available static IPs
cidr= 192.168.1.0/26         # 
[ips]
test=192.168.1.1             # Static IP for test.test.test
otherdomain.test=192.168.1.2 # Static IP for something that isn't a subdo of the tld
[addons]
otherdomain.test=1           # Mark otherdomain.test to not be a subdo of tld
[aliases]
dev=test                     # Mark dev.test.test as a CNAME of test.test.test
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
```

### recipes.yaml

Here we setup stuff we want on all our guests.

```
---
_base:
    _global:
        registrar:
            type: "testdns"
            user: "AzureDiamond"
            key: "hunter2"
        libdir:
            - '/opt/mylib'
    adminconfig:
        pkgs:
            - vim
            - tig
            - tmux
            - plocate
            - traceroute
        skel: "/opt/dotfiles/admin"
    data:
        from: "/opt/data"
        to: "/opt/domains"
    nosnap:
    nostubresolver:
        order: 0
    auditd:
    ufw:
    fail2ban:
    cron:
    letsencrypt:
```

See the relevant POD for each recipe as to what is specifically done here.

### recipes.d/test.test.test.yaml

Things we want to specifically set for this guest

```
---
test:
    _global:
        user: "test"
        size: 85899345920
        cpus: 4
        memory: 8092
    perl:
    tcms:
        tcms_dir: 'tCMS'
        order: 1
    tpsgi:
        routers:
            - 'tCMS/lib/TCMS.pm'
        basedir: 'tCMS'
    nginxproxy:
        proxy_uri: "run/tpsgi.sock"
        nocache_prefix: "/secure"
        static_dir: "www/static"
        auth_statics: "assets/private"
        auth_uri: "/authenticated"
```

## /opt/data/test.test.test

ls -a1 /opt/data/test.test.test/

```
.letsencrypt # This is created by the letsencrypt recipe, so you don't churn certs
log          # The output of tPSGI/log
tCMS         # existing tCMS install
```
