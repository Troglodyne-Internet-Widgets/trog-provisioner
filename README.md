# Troglodyne Universal Automatic Provisioning

Automatically build and host pretty much any website

## Where things are written down

| | |
|---|---|
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | the files in `/etc/trog-provisioner`, and what a guest's recipes look like |
| `perldoc Provisioner::Recipe` | writing a recipe: fragments, generated files, dependencies, tests |
| [docs/APPROACH.md](docs/APPROACH.md) | the choices a recipe is expected to make |
| [docs/BACKUPS.md](docs/BACKUPS.md) | how state survives a guest being rebuilt |
| [EXAMPLE.md](EXAMPLE.md) | a worked deployment, end to end |
| [STYLE.md](STYLE.md) and [docs/POD.md](docs/POD.md) | how we write the perl and document it |
| [t/TESTING.md](t/TESTING.md) | how we test, here and on the guest |

## WHY

Until your business is at the scale you need to distribute dynamic operations like statics with a CDN, stuff like openstack or kubernetes is overkill.

This gives you similar ease of orchestration with the supposition you are working with one or a few Hypervisors.
You'd be surprised how well this works for 99% of business purposes.
Even business units at giant corporations can do just fine with this approach.

## How it works

1. Write a configuration file (Config::Simple format) in $DOMAIN/provision.conf which tells us:
    * ips: What IPs/Gw/Resolvers to use for said domain
    * size: How big the disk oughtta be
    * image: What base image to use
    * packages: What packages to install
    * contact\_email: Email address to send root's mail to
    * depends\_on: Whether this system is to be provisioned on something that may or may not already exist
    * admin\_user: What the name of the admin user is in the event we want to provision on already existing systems.  This user needs passwordless sudo; when omitted we use root.
    * dhcp\_devname / bridge\_devname: What the guest calls its two interfaces.  Worked out from the PCI slots the domain XML pins them to -- `ens3` for the libvirt NAT, `ens4` for the outbound bridge -- so you only need these if your image names interfaces some other way.  They used to be mandatory, because what a guest called its NICs depended on the machine type and on whatever order libvirt assigned PCI slots in.  Both are pinned now, and cloud-init matches each interface by MAC rather than by name, so the name is only what it ends up called.
    * hypervisor: Pin this guest to a named hypervisor out of hypervisors.conf, when it genuinely has to live on a particular machine.  Normally you leave this out and let it be placed.  See "PROVISIONING A REMOTE HYPERVISOR" below.

    Nothing else here says anything about *where* the guest runs; that's what hypervisors.conf is for.  A guest definition that names a machine is a guest definition you can't move.
    * cpu\_mode: libvirt `<cpu mode="...">` value.  Defaults to `host-passthrough` so the guest sees the HV's real CPU (incl. AVX/AVX2 — required by anything that probes cpuid for vector extensions, e.g. the v8 snapshot bundled with the `claude` CLI).  Set to `host-model` or a specific qemu CPU model if you need to migrate the guest to a differently-specced HV.
2. Write $DOMAIN/users.yaml describing the users to create. See cloud-init's [documentation](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups) for examples.
2. Ensure tarball backups to restore (if they exist) are in the directory as data.tar.gz.
2. Run `bin/provision $DOMAIN` -- fully qualified, e.g. `bin/provision mysql.troglodyne.net` (add `--connect $URI` to build on another hypervisor)
3. It is the responsibility of data.tar.gz to have a Makefile in the TLD which sets up all relevant dependencies, loads up DBs, etc as the default target.
4. To set up new sites, have a skeleton site generator to build a blank site tarball.

This all works behind the scenes due to:
1. A small ISO, labelled `cidata`, mounted as a cdrom, carrying the network setup and cloud-config
2. libvirt's virtual networking allowing us to talk to this HV.
3. Spinning off an atd job to actually do the setup when cloud-config is done.

You'll need to have the user running this set up with at least one working authorized SSH key so we can add more.
Aside from that, clone this in /opt where the user can see it.

It is not the responsibility of this tool to ensure inappropriate setup steps in the run makefile are skipped when applying to a dependent system, or deploying to an exisiting host.

DO NOT USE ROOT TO RUN THIS!
Make sure that the user is in the qemu/kvm group (depending on running env) so you can talk to libvirt instead.
The same goes for the login you use to reach a remote hypervisor.

From there the host should "Just Work"TM.

See example.test/ for example usage.

All the relevant resources will be stored in /vms on the HV.

## PROVISIONING A REMOTE HYPERVISOR

By default the hypervisor is the machine you run `bin/provision` on.  There are two ways to build somewhere else.

### A fleet, in hypervisors.conf

Describe the machines once, in `/etc/trog-provisioner/hypervisors.conf`.  See `hypervisors.conf.example`; the short version is one `[block]` per machine:

```
[hv1]
libvirt_uri    = qemu+ssh://root@hv1.example.net/system
reserve_memory = 4096
max_guests     = 20

[hv2]
libvirt_uri    = qemu+ssh://root@hv2.example.net/system
```

From then on every tool works out which machine it wants on its own, and you go on running them exactly as you did:

```
bin/provision mysite.test
bin/destroy   mysite.test
bin/snapshot  mysite.test
bin/restore   --latest mysite.test
```

`bin/provision` **places** the guest: whichever hypervisor already has it keeps it, otherwise the roomiest one that can actually hold it wins.  Everything else **finds** it, by asking each hypervisor in turn whether it has a guest by that name.  Nothing is written down, because a file recording where a guest lives goes stale the moment somebody migrates one by hand, and libvirt never does.

Placement compares what the guest asks for -- `memory`, `cpus` and `size` from its `provision.conf` -- against what each machine has left, and refuses if none of them can take it:

```
$ bin/provision hungry.test
Nowhere to put hungry.test: it wants 65536MB of memory, 16 CPUs and 500GB of disk,
and no hypervisor in /etc/trog-provisioner/hypervisors.conf can spare that.
  hv1: needs 65536MB of memory, 24576MB free (65536MB physical, 36864MB committed, 4096MB reserved)
  hv2: needs 500GB of disk, 210GB free in the pool after a 50GB reserve
  hv2: already has 20 guests, and max_guests is 20
```

Memory is counted as *committed* rather than *used*: a guest that was promised 8G is holding 8G against the machine even while it idles at 400M, and overcommitting memory is how you get the OOM killer picking one of your VMs.  CPUs are the opposite -- overcommitting cores is normal -- so those are measured against `cpu_overcommit` times the physical count.  Of the machines that fit, the one chosen is the one whose *tightest* resource is least tight afterwards, which is what stops one machine filling its disk while the fleet still has plenty of RAM.

A guest that genuinely has to live on a particular machine can say so in its own `provision.conf`:

```
hypervisor=hv1
```

It still has to fit; a pin to a machine with no room is an error rather than a quiet reassignment.

### One machine, on the command line

Skip all of the above and say where to build:

```
bin/provision --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/destroy   --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/snapshot  --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/restore   --connect qemu+ssh://root@hv1.example.net/system --latest mysite.test
```

`--connect` bypasses `hypervisors.conf` entirely: no search, no capacity check, build it there.

Without a `hypervisors.conf`, `libvirt_uri` in a guest's `provision.conf` still works the way it used to.  It's deprecated -- it's a property of the machine, not the guest -- and it's ignored, with a warning, once a fleet exists.

### What that actually does

The URI is used for every libvirt call we make, which all go through `Sys::Virt` -- no `virsh`, so libvirt's own transports do the work.  Beyond that, a fair amount of what this tool does is not libvirt at all -- discovering the bridge devices, dropping `virtiofs-better` in `/usr/libexec`, writing the rsyslog collector config, putting the domain directory somewhere the guest can fetch it from -- and all of it has to happen *on the hypervisor*.  So for a remote URI we open one `Net::OpenSSH::More` connection there and do it over that, commands and file transfers alike.

The hypervisor and the guest are reached the same way, so both are subclasses of `Trog::Machine`, which holds the connection, the commands and the file operations.  `Trog::HV` adds libvirt and the paths; `Trog::Guest` adds the waiting a freshly built VM needs.  Nothing in either goes over sftp: `Net::SFTP::Foreign` hangs rather than failing when the far side refuses a write, so files are poured down the standard input of a command instead, and `sudo` goes in front of the write rather than in front of a move afterwards.

That means:


1. **A remote hypervisor has to be named with an ssh transport.**  `qemu+ssh://user@host/system` (or `+libssh`/`+libssh2`) tells us both how to talk to libvirt and how to get a shell.  `qemu+tcp://` and `qemu+tls://` give us libvirt but no filesystem, so they're refused up front rather than failing halfway through a build.

2. **You need passwordless SSH to the HV** as the user the URI names.  We use your `~/.ssh/config`, so jump hosts and per-host identities work as you'd expect.

    Passwordless `sudo` there is strongly preferred but no longer required: `sudo` runs with `-n`, and if the far side asks for a password you get prompted once and it's remembered for the rest of the run.  Run non-interactively -- from cron, or with stdin redirected -- and there's nobody to ask, so you get an error naming the user and the `NOPASSWD` line to add instead of a hang.

3. **The guest needs a routable address.**  We normally find a new VM by its libvirt NAT lease (`192.168.122.x`), which is only reachable from the HV itself.  When the HV is remote we SSH to the first entry in `ips` instead, so a remote build requires `ips` to be set in provision.conf.  You'll get a clear error rather than a hang if you forget.


4. **The whole domain directory is copied to the HV** at the same path, since the guest fetches its payload from there over the NAT network.  It's the whole directory and not just `data.tar.gz` because what else lives in there is decided by whatever provisions your domains, not by this repository -- we're in no position to guess which parts the guest will reach for.  Note that this puts the guest's private key on the hypervisor as well; that's the cost of the hypervisor being the machine the guest fetches from.

    Anything *outside* the domain directory that a guest expects to find on the HV -- `dir=` entries in `mounts.txt` point at hypervisor-side paths, for instance -- is not synced and never was.  Those are yours to provision.

5. **The HV still has to be set up as a hypervisor**: apt-mirror behind nginx, rsyslog listening, the bridge devices, the qemu/kvm group membership.  See UBUNTU DEPS above.  `--connect` points at a hypervisor; it doesn't build one.

### One repository, one run

`bin/new_config` and `bin/provision` used to live in separate repositories and be run one after the other: generate a domain's configuration, then build the VM.  That held together while the generator could assume it was running *on* the hypervisor it was writing about -- it read the internal IP and the sshd port straight off the local machine.  Once which hypervisor to use became a choice, both halves had to agree on the answer, and the only honest way for them to agree is to be one program.

So `bin/provision` generates the configuration first, and the generator is what picks the hypervisor: the recipe already says how much memory, disk and CPU the guest wants, which is everything placement needs.  `provision.conf` never has to carry it.  `--no-config` skips the generation and builds whatever is already in the domain directory, which is what you want for a domain you wrote by hand.

### Configuration lives in /etc/trog-provisioner

Five files, none of them in the checkout -- `hypervisors.conf`, `ipmap.cfg`,
`recipes.yaml`, `recipes.d/` and `secrets.kdbx`.  What goes in each of them is
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

They describe an *installation*, not this software.  They used to sit in the checkout, which meant `.gitignore` was the only thing between a password database and a public repository, and meant every command had to be run from one particular directory to find them.  `.gitignore` still lists them, so an old working copy can't commit one by habit.

`TROG_PROVISIONER_CONFIG` points somewhere else -- another installation, or a temporary directory in a test with no business reading the real one.  Every command also takes `--ipmap`, `--recipes` and `--hvconf` individually.

### Spinning one up from the recipes

`bin/new_guest` writes a domain configuration from a list of recipes, so a
scratch guest is one command rather than a file you copy from another guest and
edit:

```
$ bin/new_guest nginx mariadb
Wrote /etc/trog-provisioner/recipes.d/f1698301-2db6-41ec-90fd-effec2f148d4.test.yaml
f1698301-2db6-41ec-90fd-effec2f148d4.test: 2 recipes (nginx, mariadb)

Fill these in before provisioning:
  mariadb.dumpfile
  mariadb.root_pw
  mariadb.version
```

With no `--hostname` it picks a UUID under `.test`, which is a name nobody else
has and a TLD reserved for exactly this.  `--memory`, `--cpus` and `--size` are
what placement reads; the defaults are small on purpose.

Every recipe says what it takes in `args()`, an OpenAPIv3 schema, so what to
write is derivable rather than guessed: fields the recipe requires get their
default if it has one and `CHANGEME` if it does not, and fields it does not
require are left out, so the recipe's own defaults keep applying instead of
being frozen into the file the day it was generated.  Anything `_base` already
supplies is left to `_base`, which wins the merge anyway.

A `CHANGEME` that reaches `bin/new_config` stops it, naming the keys.  Without
that it would validate quite happily -- it is a string, and `root_pw` wants a
string -- and you would get a database whose root password is `CHANGEME`.

`bin/recipes` is the other half of the same thing:

```
$ bin/recipes                      # every recipe, and what it is for
$ bin/recipes mariadb              # what mariadb takes, as JSON
$ bin/recipes --scaffold mariadb   # what new_guest would write for it
$ bin/recipes --json               # the listing, for something other than a human
```

Both are `Provisioner::Cookbook` with a command line attached.  It does not
live under `lib/Provisioner/Recipe/`, because everything there is discovered
and loaded as a recipe.

### Everything is spelled out

Domains used to be written two ways: short, with a `tld` from `ipmap.cfg`'s global section appended, or fully qualified for anything under a different parent -- which the config called an "addon" and handled down a separate path.  Both spellings arrived at the same place, and the separate path existed only to undo the appending.

There is one spelling now, in full, matching what `recipes.d` already named its files:

```
bin/new_config mysql.troglodyne.net
bin/provision  mysql.troglodyne.net
```

`[addons]` and `tld` are gone from `ipmap.cfg`, and the keys in `[ips]` and `[aliases]` -- and the top-level key of each recipe -- are fully qualified.  `bin/qualify_site_data --tld yourdomain.com` does the rename once, backing both up first.  It refuses if two entries would collapse into one, which is worth knowing about: a short name and a qualified one can both be in there meaning the same machine with different addresses, and picking between them is not a decision a script should make.

### Why there is no terraform any more

There was, and every one of these is a thing it did:

* It wanted a state file per hypervisor, because one shared between two would have it believe HV A's resources lived on HV B and destroy accordingly.
* Reaching a hypervisor that had been provisioned from itself, that state started empty -- so terraform believed nothing existed and set about recreating the pool, the base image and every domain, which libvirt refused one at a time.
* Adopting what already existed needed `import` blocks, plus `ignore_changes` for every attribute the provider wouldn't report back afterwards (`target` on the pool, `create` and `backing_store` on the volumes) -- without which it planned a replacement on every run, which `prevent_destroy` then refused.
* And `libvirt_volume` can't be imported at all in 0.9.1.  It takes the id, looks for the volume, and answers `Cannot import non-existent remote object` for the volume key, its path and `pool/name` alike, on a volume it can otherwise see perfectly well.

The machinery holding all that at bay got larger than the thing it stood in for.  `bin/provision` now renders libvirt XML from `domain.xml.tmpl` and hands it to `Sys::Virt`: define the pool if it's absent, fetch the base image if it's absent, make the guest's disk as an overlay on it, build the cloud-init seed with `xorriso`, define the domain and start it.  There's no state file, because libvirt is the state.

The hypervisor needs `xorriso` (or `genisoimage`/`mkisofs`) for the seed ISO, and `curl` to fetch the base image.  Nothing else.


### Checking a hypervisor before you build on it

`bin/preflight` asks whether a provision is worth starting. Every check it makes
is one that, if it fails, fails the whole run — so they happen up front, all of
them run even after the first failure, and each one that fails says what to do:

```
$ bin/preflight
Hypervisor: qemu+ssh://doge@hv1.example.net/system

  ok   Reached doge@hv1.example.net as doge
FAILED No passwordless sudo for doge on hv1.example.net
  ok   Cloud-init seed builder: xorriso
  ok   libvirt answers, running 10.0.0
  ok   Sys::Virt 10.0.0 matches libvirt 10.0.0 on the hypervisor
  ok   Configuration to copy from: /etc/trog-provisioner
```

Exits 0 when a run is worth starting and 1 when it is not, so it works in a
script. `--connect` checks a particular hypervisor instead of whichever the
fleet would pick.

Two of these are worth the trouble because of how they fail otherwise:

**Passwordless sudo.** Provisioning writes to the storage pool, defines domains
and edits the rsyslog config, all through `sudo`. A password prompt in the
middle of that has nowhere to be answered from, so the run *hangs* rather than
failing, and you find out by waiting.

**`Sys::Virt` against the hypervisor's libvirt.** `Sys::Virt` is released in
lockstep with libvirt and binds the API of the release it was built against.
Talk to a daemon from a different one and the failure does not announce itself
as a version problem — it is a constant that is not exported, or a call the far
side does not implement, blamed on whatever was being attempted at the time.
Compared on major.minor; a patch release apart is fine.

### When a guest will not boot

`bin/provision` can only tell you a guest never asked for an address.  A guest
that never boots has no lease, no ssh and no logs to go and get, so there is
nothing to read.  `bin/debug_boot` is how you read it anyway.

Start with the console.  It points the guest's serial port at a file on the
hypervisor, restarts it, and hands back every line the kernel and systemd
printed — as text, from the first line of firmware:

```
bin/debug_boot --console vm.example.com
```

A hang is the last line before the silence.  `--fetch` re-reads that capture
without another restart, and `--shot` grabs the screen as it is now.

With libguestfs on the hypervisor, you can go further without booting anything:

```
bin/debug_boot --cat vm.example.com /var/log/cloud-init.log
bin/debug_boot --ls  vm.example.com /etc/netplan
bin/debug_boot --single vm.example.com     # then --vnc for the tunnel
```

`--single` writes `single` onto the kernel command line in the guest's own
grub.cfg and starts it, so it comes up in rescue mode by itself — no five second
window to catch and no keystrokes to get right.  The guest has to be off first,
since it is a write to its disk.  `bin/preflight` says whether libguestfs is
there; without it, `--hold` turns on the firmware boot menu and `--keys` sends
keystrokes, which is holding ESC by hand and about as reliable.

`--console`, `--hold` and `--single` all change something.  `--restore` puts the
serial port, the boot menu and the kernel command line all back.

### Nuking a wedged storage pool

A storage pool can get into a state nothing else will get it out of.  `bin/nuke_pool` removes the pool's directory from the hypervisor and then stops, deletes and undefines the pool:

```
bin/nuke_pool
bin/nuke_pool --connect qemu+ssh://root@hv1.example.net/system
```

## UBUNTU DEPS

virt-manager bridge-utils apt-mirror nginx

Expects the HV to be an apt-mirror obviously.

## IF YOU ENCOUNTER MYSTERIOUS 'cannot access image' issues

It's almost certainly that you need to add an override for those dirs in either an apparmor config for libvirt-qemu or selinux.
