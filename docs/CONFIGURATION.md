# Configuring an installation

These files describe an *installation*, not this software, and they live in
`/etc/trog-provisioner` rather than in the checkout. `TROG_PROVISIONER_CONFIG`
points somewhere else; every command also takes `--ipmap`, `--recipes` and
`--hvconf` individually.

| | |
|---|---|
| `hypervisors.conf` | the machines you can build on, and what to spare on each |
| `ipmap.cfg` | addresses, nameservers, the address pool, and who administers it all |
| `recipes.yaml` | the base recipe every guest gets |
| `recipes.d/` | one file per guest, named for it |
| `secrets.kdbx` | the passwords the recipes reach for |

Domains are always written in full. There is no `tld` to append to a short name
and no separate path for anything under a different parent: `[ips]`, `[aliases]`
and the top-level key of every recipe all name a fully qualified domain.
`bin/qualify_site_data --tld yourdomain.com` does the rename once if you are
coming from an older installation.

## ipmap.cfg

Static addresses for guests, and the details every domain inherits.

```
[global]
basedir=/opt/domains
admin_user=test
admin_key=gh:test
admin_gecos=Testy Testerson
admin_email=test@test.test
[ips]
tickle.test.test=192.168.1.1
[aliases]
tickle.test.test=chase.test.test, kiss.test.test
[nameservers]
ns1=ns1.test.test
ns2=ns2.test.test
```

`basedir` is where the generated configuration for each domain lands **on the
hypervisor**, one directory per fully qualified name. It is easy to confuse with
the `data` recipe's `to`, which is where things land **on the guest**; they are
frequently both `/opt/domains`, and they are not the same directory.

`bin/new_config tickle.test.test` writes a configuration for that name at that
address. It populates a `users.yaml` creating the admin user, granting them
admin rights and importing their GitHub key; you can add to that with a
`users.yaml` in the data directory. Aliases become vhost aliases and CNAMEs if
you have picked the recipes that do that.

## recipes.yaml and recipes.d/

What each guest is made of. `recipes.yaml` holds what every guest gets;
`recipes.d/` holds one file per guest, named for it. Both are read the same way.

```yaml
---
tickle.test.test:
    _global:
        user: my_service_user
        registrar:
            type: "cloudflare"
            user: "someGuy"
            key:  "secret:troglodyne/cloudflare/password"
        size: disk_size_in_bytes
        memory: ram_size_in_mb
        cpus:  num_cpus
    data:
        from: /opt/client-data
        to:   /opt/domains
    adminconfig:
        skel: "/opt/dotfiles/test"
        pkgs: [vim, tig, tmux, plocate]
    perl:
    tpsgi:
    fail2ban:
    letsencrypt:
    ufw:
        port_forwards:
            - from: 25
              to: 2500
    cron:
        from: "cron"
        root_scripts:
            - cmd: "do_some_other_thing"
              interval: "*/5 * * * *"
              mailto: "foo@bar.baz"
    nginxproxy:
        proxy_uri: http://localhost:5000
    pdns:
        soa: "ns1.test.test"
```

See [EXAMPLE.md](../EXAMPLE.md) for a worked one, and each recipe's own POD
(`perldoc Provisioner::Recipe::nginxproxy`) for what it takes.

A password is never written here. `secret:GROUP/ENTRY/FIELD` names an entry in
`secrets.kdbx` and is resolved when the configuration is read -- see
`Trog::Secrets`.

## `_global`

Variables every recipe's templates for that domain can see.

`user` is the one to know about: the service account the application runs as,
which recipes set ownership to. Leaving it unset gives you the admin user, which
is what you want while developing; a production host generally names one.

## `_base`

A top-level `_base` holds recipes every host gets. A domain's own configuration
is merged over it, so anything it sets wins.

## `_shared`

Guests that share a machine, rather than getting one each:

```yaml
---
_shared:
    my.shared.host:
        - my.client.on.shared.host
my.shared.host:
my.client.on.shared.host:
    ...
```

The shared host is built first, then each guest on it is built against the
running machine.

## Data directories

The `data` recipe rsyncs `from/<domain>` on the hypervisor to `to/<domain>` on
the guest, and that path is what templates see as `data_dir`. With the example
above, `/opt/client-data/tickle.test.test` on the hypervisor arrives at
`/opt/domains/tickle.test.test` on the guest.

It is also where `remote_files` puts what it salvages off an existing guest, so
the data directory is both what you restore from and what a backup tars up.

## Recipes that pull in other recipes

Most recipes that need another one configure it themselves, so asking for the
application is usually enough:

```yaml
    tpsgi:
```

That gets an `nginxproxy` with vhosts on 80 and 443, because that is what a
proxied application almost always wants. Say it yourself when it is not:

```yaml
    tpsgi:
        nginxproxy:
            vhosts:
                8080:
                    proxy_uri: /foo/whatever.sock
                    nocache_prefix: "/secure"
                    static_dir: "www/static"
                    ssl: true
```

Configuring a dependency explicitly replaces the default for it rather than
adding to it. Dependencies of dependencies work, and several recipes can layer
onto one shared dependency -- `tcms` builds on `tpsgi` and adds to the same
vhost.

Where two of them ask for the same field and disagree, the recipe being depended
on decides, and **dies** if it has no rule for that field: two applications both
claiming a domain's 443 vhost is a misconfiguration rather than something to
settle by merge order. `ufw` is the exception that has a rule -- two recipes
listening on one port both get the higher of their rate limits. See
`Provisioner::Recipe::resolve_conflict`.

## Known gaps

Two the old documentation carried, both still true:

* `admin_key` is handed to cloud-init as an `ssh_import_id`, so it names an
  account to import from (`gh:someone`) rather than a key. A raw public key has
  no way in here; put it in the domain's `users.yaml`, which takes
  `ssh_authorized_keys`.
* A few recipes -- `mail` most of all -- are not idempotent the way the global
  fragment mechanism wants, because the software they configure has no `conf.d`
  directory and the config file has to be edited rather than added to.

## Writing a recipe

`perldoc Provisioner::Recipe` -- it covers the makefile fragment contract, the
global and per-domain halves, generated files, salvaged files, tests, and the
conventions a recipe is expected to keep. [STYLE.md](../STYLE.md) covers how we
write the perl itself, and [APPROACH.md](APPROACH.md) the choices a recipe
should make.
