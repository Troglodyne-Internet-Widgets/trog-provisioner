# Configuring an installation

These files describe an *installation*, not this software, and they live in
`/etc/trog-provisioner` rather than in the checkout. `TROG_PROVISIONER_CONFIG`
points somewhere else; every command also takes `--recipes` and `--hvconf`
individually.

| | |
|---|---|
| `hypervisors.conf` | the machines you can build on, and what to spare on each |
| `admin_authorized_keys` | the administrator's public keys, written into every guest cloud-init builds |
| `recipes.yaml` | the settings every guest shares, and the base recipe every guest gets |
| `recipes.d/` | one file per guest, named for it |
| `secrets.kdbx` | the passwords the recipes reach for, and a cloud's credential secret when `clouds.yaml` refers to it |

Domains are always written in full. There is no `tld` to append to a short name
and no separate path for anything under a different parent: the top-level key of
every recipe names a fully qualified domain.
An older installation must run `bin/qualify_site_data` once.  The tool is
removed, and this prints it from the history:

    git show $(git log -1 --format=%H --diff-filter=D -- bin/qualify_site_data)^:bin/qualify_site_data

## The settings every guest shares

They are the `_global` of `_base` in `recipes.yaml`, and a domain overrides one
in its own `_global`. `Provisioner::Cookbook->global_schema` declares them, and
`bin/new_config` refuses to build a guest while one that is required is missing.

```yaml
_base:
  _global:
    basedir: /opt/domains
    admin_user: test
    admin_gecos: Testy Testerson
    admin_email: test@test.test
    gateway: 192.0.2.254
    resolvers: [192.0.2.254, 8.8.8.8]
    nameservers:
      ns1: ns1.test.test
      ns2: ns2.test.test

tickle.test.test:
  _global:
    aliases: [chase.test.test, kiss.test.test]
```

These used to be a second file, `ipmap.cfg`, in the format `Config::Simple`
reads. An installation that still has one moves it across in one command:

    bin/ipmap_to_globals --dryrun
    bin/ipmap_to_globals

The addresses of the guests are not moved. They live in `ips.db`, which
`Provisioner::IPPool` owns, and nothing has read them out of a file since
`bin/assign_ip` took over handing them out.

`basedir` is where the generated configuration for each domain lands **on this
machine**, one directory per fully qualified name. It is easy to confuse with
the `data` recipe's `to`, which is where things land **on the guest**; they are
frequently both `/opt/domains`, and they are not the same directory.

`gateway` and `resolvers` are required, and every guest is built with them:
`resolvers` becomes the nameservers in its network configuration and the list
its resolver is pointed at.

**Do not put a loopback address in `resolvers`.** It answers only on a guest
running its own DNS server, and for that guest
`Provisioner::Recipe::nostubresolver` puts `127.0.0.1` in front by itself. Named
here it reaches every guest, and on the rest nothing is listening there — a
wasted lookup each time, and `Provisioner::Recipe::fetchcache` strips it back
out of the list it hands nginx. `bin/new_config` refuses one rather than
letting it through.

Three optional settings say how a guest reaches back here for its payload, and
none is normally needed:

```yaml
    transfer_user: whoever_runs_trog_provisioner
    transfer_ip: 192.0.2.10
    transfer_port: 22
```

The account defaults to whoever is running the tool, the port to what this
machine's `sshd_config` says, and the address to whichever of ours a guest on
the hypervisor's network can route to. Set `transfer_ip` when this machine has
more than one way to be reached and the kernel picks the wrong one.

`bin/new_config tickle.test.test` writes a configuration for that name at that
address. It populates a `users.yaml` creating the admin user, granting them
admin rights and authorizing the keys from `admin_authorized_keys`; you can add
to that with a `users.yaml` in the data directory. Aliases become vhost aliases
and CNAMEs if you have picked the recipes that do that.

## admin_authorized_keys

The administrator's public keys, one per line, in the format sshd reads. Blank
lines and `#` comments are ignored. Every guest cloud-init builds is given
these, on the account that can sudo.

`bin/preflight` checks the file is there and offers to fill it in from an online
identity when there is a terminal to ask at. To do it by hand:

```
ssh-import-id -o /etc/trog-provisioner/admin_authorized_keys gh:yourname
```

`lp:` for Launchpad. A key you have locally can simply be appended; nothing here
requires that they came from a service.

This used to be a single `admin_key` in the settings naming an identity
(`gh:someone`) which cloud-init resolved **on the guest, at first boot**. That
made every provision wait on GitHub answering, and fail when it did not -- and a
raw public key had no way in at all. Holding the keys here resolves them once,
where a failure is somebody's to look at rather than a guest that will not come
up.

## recipes.yaml and recipes.d/

What each guest is made of. `recipes.yaml` holds what every guest gets;
`recipes.d/` holds one file per guest, named for it. Both are read the same way.

```yaml
---
tickle.test.test:
    _global:
        user: my_service_user
        size: disk_size_in_bytes
        memory: ram_size_in_mb
        cpus:  num_cpus
        data_source: /opt/client-data
        install_dir: /opt/domains
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
    registrar:
        type: "cloudflare"
        user: "someGuy"
        key:  "secret:registrar/cloudflare/password"
```

`registrar` is a recipe rather than a `_global` setting, and usually lives in
`_base` so every domain inherits one. It says who holds a domain's public zone
so dehydrated can write an `_acme-challenge` record into it; `pdns` says the
guest holds its own. Both implement `Provisioner::DNSRecipe`, and a guest with
both is ambiguous -- `letsencrypt`'s `dns_preference` names which of the two
serves this name, and a guest with both and no preference is refused rather
than guessed at. A name under a TLD RFC 2606 reserves is always served locally,
because no public registrar can hold a zone for one.

Credentials written under `_global` are refused, naming the domain: they used to
live there and nothing reads them now.

See [EXAMPLE.md](../EXAMPLE.md) for a worked one, and each recipe's own POD
(`perldoc Provisioner::Recipe::nginxproxy`) for what it takes.

`_global` also carries the settings that describe how the **hypervisor** builds
the guest rather than what goes on it: `size`, `memory` and `cpus`, and
optionally `machine`, `cpu_mode` and the `disk_*` keys. Those belong to the `vm` recipe, so
`bin/recipes vm` prints what each of them is and what it defaults to. They are
copied into the guest's `provision.conf`, which is where `bin/provision` reads
them.

Those three describe a guest on a machine of ours. A hypervisor that sells sizes
by name asks instead for the one you want, and each has a key of its own:
`linode_type` for Linode, `openstack_flavor` for OpenStack. A guest that names
none is not built on that kind of hypervisor at all, which is how a guest is
kept off a cloud, and off the bill. `memory`, `cpus` and `size` still say what
the guest needs, and placement refuses a type too small to hold it.

`machine` is the libvirt machine type, and it is `q35` by default: a guest gets
a PCIe topology, which is what an assigned PCIe device needs.  `pc` asks for the
older i440fx instead.  It decides the PCI topology the guest knows, so changing
it on a guest that exists is a new machine to that guest.

The `disk_*` ones are all optional and none of them are emitted blind -- the `vm`
recipe asks the hypervisor's libvirt and qemu what they will accept and leaves
out anything they will not, so the same `recipes.yaml` builds on a machine that
has not been reinstalled since 20.04 and on one that has. The guest's own side of
the same disk is the `diskqueue` recipe.

A password is never written here. `secret:GROUP/ENTRY/FIELD` names an entry in
`secrets.kdbx` and is resolved when the configuration is read -- see
`Trog::Secrets`.

The same reference works in two other files, for the same reason. Any value in a
`hypervisors.conf` block can be one, which is where a Linode token belongs; it is
resolved when something reads that value, so a run that touches no hypervisor
whose block holds one is never asked for the passphrase. In `clouds.yaml`, the
`application_credential_secret` can be one, and `Trog::OpenStack::Auth` resolves
it only when it has to ask Keystone for a token. A reference in any other value
of that file is refused when it is read, because nothing resolves those.

Nothing else that reads `clouds.yaml` understands a reference: the OpenStack
tools read the file as it is written, so they send the reference itself to
Keystone and get a 401 that explains nothing. `bin/openstack-env` resolves the
credential and prints the environment they do read, so
`eval "$(bin/openstack-env)"` gives you a shell that `openstack` works in. It
refuses to print to a terminal, where the secret would stay in the scrollback.

The group is part of the address. `secret:koan/somebox-github-ssh/password` and
`secret:github/somebox-github-ssh/password` are two different secrets, and an
entry is only found in the group its reference names. Two entries of one name
inside one group are refused, naming the group, because nothing can choose
between them.

`bin/add_secret` writes one, `bin/forget_secret` removes one, and
`bin/regroup_secrets` is a one-time repair: `Trog::Secrets` used to drop the
group on the way to the database, so every entry this tooling wrote landed in
the root group whatever its reference said. Run it once after upgrading, with
`--dryrun` first. Until it has run, the entries the tooling wrote are where the
new code does not look, and a reference that resolves to nothing is one that
`bin/new_config` generates a fresh value for.

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
        mirror: aptmirror.example.test          # a domain here, resolved to its address
        # mirror: http://mirror.example.test/ubuntu   # or a URL, used as written
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

`cache` names a fetch cache for guests to provision through: a domain here,
resolved to its address, or an IPv4 address. While a guest provisions, each host
its recipes download from -- what they name in `fetch_hosts`, which
`perldoc Provisioner::Recipe` describes -- is pointed at the cache in the
guest's `/etc/hosts`. So a template's `https://github.com/...`, cpanm and git
are answered by the cache without knowing it is there, and every host goes back
to upstream once the guest's deferred work is done.

```yaml
_base:
    _global:
        cache: fetchcache.test
```

To have one to name, give a domain the `fetchcache` recipe. It fetches from those
hosts on a guest's behalf, keeps what it fetched, and hands out what it already
has when upstream is failing, which is the point of it: GitHub answering 503 for
an hour stops being an hour of failed builds. It answers under the hosts' own
names, with a certificate signed by an authority `bin/new_config` makes in the
configuration directory the first time one is needed, and a guest trusts that
authority only while it provisions. `perldoc Provisioner::Recipe::fetchcache`
has how long it keeps what, and how to add a host.

A guest points a host at the cache only if the cache answers for it when the
guest starts, so a cache that is down costs a build nothing. **Empty by
default**, which is every download going straight upstream, as it always has.
Nothing requires the recipe, and the cache itself fetches from upstream rather
than from itself.

`cpan_notest` skips the test suites of what is installed from CPAN, and is
**on by default**: a guest has ninety minutes for its makefile and deferred work
together, and the suites of everything a recipe like `trogrunner` installs under
a freshly built perl do not fit. It is the `perl` recipe's -- every recipe that
installs from CPAN depends on that one and hands it what to install -- and set
here in `_global` it reaches every guest's. Turn it off when what you are
testing is what gets installed, and a failing suite is the thing to find; the
provisioning-recipes skill's `scratch_config --cpan-tests` does that for a
scratch build. What each recipe installs is what it hands the `perl` recipe:
`perldoc Provisioner::Recipe::perl`.

## Where a guest sends its logs

Two recipes, and neither reaches onto the other's machine. `logshipper` goes on
the guests that send; `logcollector` goes on the guest that keeps what arrives.

```yaml
_base:
    logshipper:
        host: logs.example.test        # every guest ships

logs.example.test:
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
runner.example.test:
    trogrunner:
        checkout: 0                   # this one manages its own repositories
        deps_from:
            - /srv/code/trog-provisioner

        config:
            resolvers: "192.0.2.254, 1.1.1.1"
            addresses: 192.0.2.180-192.0.2.199
            cidr:      192.0.2.0/24

        hypervisors:
            hv1:
                libvirt_uri: qemu+ssh://runner@hv1.example.test/system
                pool_path:   /srv/vm-disks/runner
                pool_name:   runner_disks
                partition:   /machine/runner

        hypervisor_access: least

        recipes:
            _base:
                _global:
                    install_dir: /opt/domains
```

Nothing in it is required, and `config` inherits `admin_user`, `admin_email`,
`admin_keys` and `gateway` from the guest's own -- a runner administers what it
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
That is what `Hash::Merge` does under every behavior it has, so it is worth
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

A recipe that needs the machine rather than the domain -- the DNS server's
credential belongs to one guest however many domains it serves -- asks
`Provisioner::Cookbook->host_of`, which is this list read back.

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

A recipe can also declare a **substitutable dependency** -- depending on a
capability rather than on a recipe by name:

```yaml
    letsencrypt:
        dns_preference: pdns
```

`letsencrypt` needs something that can answer a dns-01 challenge, which is
`Provisioner::DNSRecipe` -- implemented by `pdns`, which serves the zone from the
guest, and by `registrar`, which is whoever holds it publicly. It asks for the
interface -- a substitutable dependency -- and the depsolver resolves that to
whichever serves this domain and builds it.

Which one is the interface's to decide, not the depsolver's: a name under a
reserved TLD is always served locally, a domain configured with one of the two
uses it, and a guest with both is a tie. `dns_preference` settles the tie, read
out of the configuration of whichever recipe declared the dependency -- so it
goes under `letsencrypt`, where you already write it. A guest with both and no
preference is refused rather than guessed at.

Where two of them ask for the same field and disagree, the recipe being depended
on decides, and **dies** if it has no rule for that field: two applications both
claiming a domain's 443 vhost is a misconfiguration rather than something to
settle by merge order. `ufw` is the exception that has a rule -- two recipes
listening on one port both get the higher of their rate limits. See
`Provisioner::Recipe::resolve_conflict`.

## Known gaps

One, carried over from the old documentation and still true:

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
