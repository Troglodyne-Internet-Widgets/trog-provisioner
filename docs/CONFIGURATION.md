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

`basedir` is where the generated configuration for each domain lands **on this
machine**, one directory per fully qualified name. It is easy to confuse with
the `data` recipe's `to`, which is where things land **on the guest**; they are
frequently both `/opt/domains`, and they are not the same directory.

Two optional settings say how a guest reaches back here for its payload, and
neither is normally needed:

```
transfer_user=whoever_runs_trog_provisioner
transfer_ip=192.0.2.10
transfer_port=22
```

The account defaults to whoever is running the tool, the port to what this
machine's `sshd_config` says, and the address to whichever of ours a guest on
the hypervisor's network can route to. Set `transfer_ip` when this machine has
more than one way to be reached and the kernel picks the wrong one.

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

`_global` also carries the settings that describe how the **hypervisor** builds
the guest rather than what goes on it: `size`, `memory` and `cpus`, and
optionally `cpu_mode` and the `disk_*` keys. Those belong to the `vm` recipe, so
`bin/recipes vm` prints what each of them is and what it defaults to. They are
copied into the guest's `provision.conf`, which is where `bin/provision` reads
them.

The `disk_*` ones are all optional and none of them are emitted blind -- the `vm`
recipe asks the hypervisor's libvirt and qemu what they will accept and leaves
out anything they will not, so the same `recipes.yaml` builds on a machine that
has not been reinstalled since 20.04 and on one that has. The guest's own side of
the same disk is the `diskqueue` recipe.

A password is never written here. `secret:GROUP/ENTRY/FIELD` names an entry in
`secrets.kdbx` and is resolved when the configuration is read -- see
`Trog::Secrets`.

## `_global`

Variables every recipe's templates for that domain can see.

`user` is the one to know about: the service account the application runs as,
which recipes set ownership to. Leaving it unset gives you the admin user, which
is what you want while developing; a production host generally names one.

`distro` is the other. It names the distribution the guest is built on, which
decides three things nothing else can: the cloud image its disk is layered over,
the packager the makefile invokes, and which version of each recipe supplies the
package names -- `Provisioner::Recipe::Ubuntu::nginx` rather than
`Provisioner::Recipe::nginx`. It defaults to `ubuntu`, which is what every guest
built before there was anywhere to say so is running, so an existing
`recipes.yaml` needs no change:

```yaml
_base:
    _global:
        distro: ubuntu
```

A name that is not one of `lib/Provisioner/Recipe/`'s distribution directories
is refused up front, rather than quietly falling back to recipes that name no
packages at all. `perldoc Provisioner::DistroRecipe` is what a distribution has
to answer for; adding one is adding files.

`mirror` names a package mirror for guests to prefer over the distribution's own
archive. Two shapes:

```yaml
_base:
    _global:
        mirror: aptmirror.example.com          # a domain here, resolved to its address
        # mirror: http://mirror.example.net/ubuntu   # or a URL, used as written
```

To have one of your own to name, give a domain the `aptmirror` recipe and build
it like any other guest; `perldoc Provisioner::Recipe::aptmirror` covers how big
a mirror is and how to seed one from a mirror you already have. Nothing requires
that recipe, and nothing points at the guest until you write it in here.

A **URL** is used exactly as given, which is how you name a mirror this
installation does not run. **Anything else is a domain name**, and is resolved to
that domain's address out of the ip pool with the distribution's path appended --
not through DNS, because a guest runs cloud-init before it has a resolver, so a
name would be no use to it. A bare name the pool has no address for is an error
saying to use a URL instead.

Whichever you give, the distribution's own archive stays configured behind it, so
a mirror that is behind, incomplete or down costs a fallback rather than a build.

**Empty by default, and empty means no mirror**: the guest uses whatever sources
its image shipped with, which is a per-region archive cloud-init chose, and gets
no `/etc/apt/mirrorlist` at all.

> **Upgrading.** Guests used to be told unconditionally that there was a mirror
> on their hypervisor's NAT address, whether or not one was running. If yours
> *is*, set it explicitly to keep it -- `mirror: http://192.168.122.1/ubuntu`,
> using that hypervisor's bridge address. If you run one on each hypervisor and
> they are on different subnets, no single value can name them all; the honest
> answer there is one mirror guest that the whole fleet points at.

`mirror_insecure` lets apt install from a repository it cannot verify. It
defaults to on when a mirror is configured and off when one is not, which is what
every guest has had. Turn it off against a mirror that carries the archive's own
signed indices -- one built by the `aptmirror` recipe does, being a byte-for-byte
copy.

Nothing depends on the `aptmirror` recipe. A fleet without a mirror builds
exactly as it always has, only slower, and `bin/preflight` says so rather than
failing. `perldoc Provisioner::Recipe::aptmirror` has the sizes, which are the
first thing to know before building one.

`cache` names a fetch cache for guests to download through: release tarballs,
install scripts, anything a recipe fetches with `scripts/fetch`. Named the same
two ways as `mirror` -- a domain here, resolved to its address, or a URL used as
written:

```yaml
_base:
    _global:
        cache: fetchcache.example.com
```

To have one to name, give a domain the `fetchcache` recipe. It fetches from a
fixed list of upstreams on a guest's behalf, keeps what it fetched, and hands out
what it already has when upstream is failing, which is the point of it: GitHub
answering 503 for an hour stops being an hour of failed builds.
`perldoc Provisioner::Recipe::fetchcache` has how long it keeps what, and how to
add an upstream.

A guest asks the cache first and upstream after it, so a cache that is down
costs a few seconds a download rather than a build. **Empty by default**, which
is every download going straight upstream, as it always has. Nothing requires
the recipe, and the cache itself fetches from upstream rather than from itself.

## Where a guest sends its logs

Two recipes, and neither reaches onto the other's machine. `logshipper` goes on
the guests that send; `logcollector` goes on the guest that keeps what arrives.

```yaml
_base:
    logshipper:
        host: logs.example.com        # every guest ships

logs.example.com:
    logcollector:
        retain: 52
```

`logshipper`'s **`host` is required and has no default**. There is no "off"
setting, because a guest that does not run the recipe already ships nowhere and
keeps its own logs -- so a guest that names the recipe and does not say where to
send is a mistake, and the build stops rather than forwarding nothing. `port`
(514), `protocol` (`tcp`) and `selector` (`*.*`) are settings rather than
constants; the selector is where you decide how much of a guest's log stream is
worth sending at all.

**A name the ip pool has an address for is resolved to that address**, so logs
from inside this installation do not need DNS to arrive -- including the logs
that would tell you DNS is down. Anything else is used as written, which is how
you name a syslog service somebody else runs. A guest configured to ship to
itself ships nowhere and says so, since one `_base` block necessarily covers the
collector too.

`logcollector` writes one file per sending host under `log_dir`
(`/var/log/hosts`), routing on the hostname in each message rather than on a
list of senders -- it is built before most of the guests that will ship to it
exist, so it cannot have one. A new guest starts logging there the moment it is
built, and nothing has to be added anywhere.

Nothing depends on either recipe, and `bin/preflight` says so rather than
failing when a collector is built and nothing points at it.

> **Upgrading.** Guests used to be told, unconditionally, that their logs went to
> their hypervisor's NAT address, and provisioning wrote a per-domain collector
> configuration onto the hypervisor to match. Neither half asked whether anything
> there was listening, and a guest cannot tell: rsyslog queues, retries, suspends
> and discards without logging a word. If your hypervisor **is** a working
> collector, keep using it with `logshipper: { host: <its bridge address> }` --
> an address, since it is not a domain the pool knows. Otherwise build a
> `logcollector` guest. `bin/preflight` lists the drop-ins left on the hypervisor
> and the command to remove them.

## A guest that builds guests

`trogrunner` makes a guest able to run this software: a perl new enough to load
it, the CPAN dependencies, an `/etc/trog-provisioner` of its own, and -- when
asked for one -- a key a hypervisor will trust.

```yaml
runner.example.com:
    trogrunner:
        checkout: 0                   # this one manages its own repositories
        deps_from:
            - /srv/code/trog-provisioner

        config:
            resolvers: "192.168.1.254, 1.1.1.1"
            addresses: 192.168.1.180-192.168.1.199
            cidr:      192.168.1.0/24

        hypervisors:
            hydra:
                libvirt_uri: qemu+ssh://runner@hydra.example.com/system
                pool_path:   /pool/vm-disks/runner
                pool_name:   runner_disks
                partition:   /machine/runner

        hypervisor_access: least

        recipes:
            _base:
                _global:
                    install_dir: /opt/domains
```

Nothing in it is required, and `config` inherits `admin_user`, `admin_email`,
`admin_key` and `gateway` from the guest's own -- a runner administers what it
builds the way this installation administers it, unless told otherwise. Give it
`addresses` and `cidr` though: without an address pool it has none to hand out,
and every guest it tries to build stops on "cannot auto-assign IP".

Four more parts are worth knowing before writing one.

**It takes longer than the default budget allows.** A runner builds perl from
source, runs the test suite of every distribution that goes on top of it, and
only then installs the forty-odd this repository declares. Measured on a
four-CPU guest that does not fit the ninety minutes `Trog::Guest` allows, so
build one with `TROG_SETUP_TIMEOUT=3h bin/provision <domain>`. (How much of that
is avoidable is #123.) Forgetting costs
you the guest test result and nothing else -- the queue runs under `atd` on the
guest and carries on after `bin/provision` has stopped waiting.

**`checkout` is optional** because a runner that manages its own repositories --
a coding agent, say -- already has one, and a second copy under `install_dir` is
a second copy to get out of step. Set it to `0` and name the path it does clone
to in `deps_from`; the dependencies get installed either way.

`deps_from` is additive rather than an alternative, so it is optional whichever
way `checkout` is set: every path in it gets `dzil authordeps` and `dzil
listdeps` run against it, and the checkout this recipe makes gets the same
treatment when there is one. A runner with both ends up with the union.

**Secrets in `recipes` are written `store:`, not `secret:`.** `bin/new_config`
resolves every `secret:` reference in the whole configuration before any recipe
is built, so one written in here would arrive resolved and be dumped into the
runner's `recipes.yaml`, into `data.tar.gz` and into every backup of the domain.
`store:GROUP/TITLE/FIELD` passes through untouched and comes out the other end
as `secret:GROUP/TITLE/FIELD` -- a reference, like a hand-written `recipes.yaml`
holds, which the runner resolves against its own store.

**`hypervisor_access` defaults to `none`.** `least` is a sudo grant for the
libvirt lease helper plus libvirt group membership, which is all a provision
needs; `full` is `NOPASSWD:ALL`, which is only wanted for a first-ever
`virtiofs-better` install.  The key itself is made either way and kept in the
secret store, so a rebuild reuses it rather than accumulating a new one;
`bin/provision` is what writes the public half into each hypervisor's
`authorized_keys`, and `bin/destroy` is what takes it out again.  What the
runner still cannot be held to is a quota -- see the hypervisor section of the
[README](../README.md), and `perldoc Provisioner::Recipe::trogrunner`.

## `_base`

A top-level `_base` holds recipes every host gets. A domain's own configuration
is merged over it, so anything it sets wins.

Nested objects merge key by key, so a domain saying one thing about a recipe
keeps everything else `_base` said about it. **Lists concatenate rather than
replace**: a domain naming a list `_base` also names gets both, in that order.
That is what `Hash::Merge` does under every behaviour it has, so it is worth
knowing before putting a list in `_base` that a domain might want to narrow.

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

The `data` recipe rsyncs `from/<domain>` on this machine to `to/<domain>` on the
guest, and that path is what templates see as `data_dir`. With the example
above, `/opt/client-data/tickle.test.test` here arrives at
`/opt/domains/tickle.test.test` on the guest.

The guest fetches it from here directly. It used to be shipped to the
hypervisor first so the guest could pull it from there, which meant a domain's
data crossed the network twice per provision and the guest's private key lived
on the hypervisor; neither is true now. What that costs is a requirement: a
guest has to be able to reach this machine, and `bin/preflight` says whether it
can.

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
* A few recipes -- `mail` most of all -- were not idempotent the way the global
  fragment mechanism wants, because the software they configure has no `conf.d`
  directory and the config file had to be edited rather than added to. The
  `configd` recipe closes most of this: postfix, opendkim, opendmarc and redis
  now get a fragment directory each, so `mail` and `redis` write a file named
  for the domain instead of rewriting the service's config. What is left is the
  settings that genuinely cannot have two values -- postfix's `myhostname` and
  its TLS certificate, opendmarc's `AuthservID` -- and the postfix map files,
  which are still one per guest written by whichever domain provisioned last.
  Those are visible now (`configd status postfix` lists the fragments and who
  wrote them) rather than silent.

## Writing a recipe

`perldoc Provisioner::Recipe` -- it covers the makefile fragment contract, the
global and per-domain halves, generated files, salvaged files, tests, and the
conventions a recipe is expected to keep. [STYLE.md](../STYLE.md) covers how we
write the perl itself, and [APPROACH.md](APPROACH.md) the choices a recipe
should make.
