# Example Usage

Herein lie some examples of trog-provisioner usage.

## Deploy a tCMS site

With the following data in the noted files and directories, you can provision
a tCMS site hosted by tPSGI at test.test.test:

### recipes.yaml, the settings every guest shares

```yaml
_base:
    _global:
        basedir: /opt/domains          # Where a generated configuration lands here
        transfer_user: me              # The account that runs trog-provisioner
        admin_user: you                # The account that administers the guests
        admin_email: test@test.test    # MAILTO for most crons
        admin_gecos: Testy McTester    # Who to blame

test.test.test:
    _global:
        aliases: [dev.test.test]       # dev.test.test is a CNAME of it
```

The administrator's public keys are not in here.  They are one per line in
`admin_authorized_keys` beside it, and `bin/preflight` offers to seed that file.

### hypervisors.conf, what the network of each hypervisor gives its guests

```ini
[hv1]
libvirt_uri = qemu+ssh://hv1.test.test/system
resolvers   = 192.0.2.254, 1.1.1.1
gateway     = 192.0.2.254
pool_cidr   = 192.0.2.0/26
```

The guests of `hv1` resolve names through `resolvers`, route through `gateway`,
and get their static addresses from `pool_cidr`.  `docs/CONFIGURATION.md` has
the rest of the keys of a block.

### recipes.yaml, what the guests are made of

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
    tcms:
        tcms_dir: 'tCMS'
        order: 1
```

Note that we didn' have to setup any of the things tCMS depends on in config.
This is because it declares its dependencies, which then autoconfigure what is possible to autoconfigure.

## /opt/data/test.test.test

ls -a1 /opt/data/test.test.test/

```
.letsencrypt # This is created by the letsencrypt recipe, so you don't churn certs
log          # The output of tPSGI/log
tCMS         # existing tCMS install
```
