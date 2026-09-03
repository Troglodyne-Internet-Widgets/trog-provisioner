# Troglodyne Universal Automatic Provisioning

Automatically build and host pretty much any website

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
    * hypervisor: Pin this guest to a named hypervisor out of hypervisors.conf, when it genuinely has to live on a particular machine.  Normally you leave this out and let it be placed.  See "PROVISIONING A REMOTE HYPERVISOR" below.

    Nothing else here says anything about *where* the guest runs; that's what hypervisors.conf is for.  A guest definition that names a machine is a guest definition you can't move.
    * cpu\_mode: libvirt `<cpu mode="...">` value.  Defaults to `host-passthrough` so the guest sees the HV's real CPU (incl. AVX/AVX2 — required by anything that probes cpuid for vector extensions, e.g. the v8 snapshot bundled with the `claude` CLI).  Set to `host-model` or a specific qemu CPU model if you need to migrate the guest to a differently-specced HV.
2. Write $DOMAIN/users.yaml describing the users to create. See cloud-init's [documentation](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups) for examples.
2. Ensure tarball backups to restore (if they exist) are in the directory as data.tar.gz.
2. Run `bin/provision $DOMAIN` (add `--connect $URI` to build on another hypervisor)
3. It is the responsibility of data.tar.gz to have a Makefile in the TLD which sets up all relevant dependencies, loads up DBs, etc as the default target.
4. To set up new sites, have a skeleton site generator to build a blank site tarball.

This all works behind the scenes due to:
1. Terraform's libvirt provider mounting a bogus cdrom with network setup and cloud-config
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

Describe the machines once, in `hypervisors.conf` beside your domain directories (so `/opt/domains/hypervisors.conf` by default).  See `hypervisors.conf.example`; the short version is one `[block]` per machine:

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
and no hypervisor in /opt/domains/hypervisors.conf can spare that.
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

The URI is handed to terraform's libvirt provider and used for every libvirt call we make, which all go through `Sys::Virt` -- no `virsh`, so libvirt's own transports do the work.  Beyond that, a fair amount of what this tool does is not libvirt at all -- discovering the bridge devices, dropping `virtiofs-better` in `/usr/libexec`, writing the rsyslog collector config, putting the domain directory somewhere the guest can fetch it from -- and all of it has to happen *on the hypervisor*.  So for a remote URI we open one `Net::OpenSSH::More` connection there and do it over that, commands and file transfers alike.

The hypervisor and the guest are reached the same way, so both are subclasses of `Trog::Machine`, which holds the connection, the commands and the file operations.  `Trog::HV` adds libvirt and the paths; `Trog::Guest` adds the waiting a freshly built VM needs.  Nothing in either goes over sftp: `Net::SFTP::Foreign` hangs rather than failing when the far side refuses a write, so files are poured down the standard input of a command instead, and `sudo` goes in front of the write rather than in front of a move afterwards.

That means:

1. **Terraform's libvirt provider is told about SSH explicitly.**  libvirt's own client shells out to `ssh`, so it gets `~/.ssh/config`, your agent and `ProxyJump` for free.  The terraform provider dials SSH itself in Go and reads none of that -- if your key is in an agent and there's no `id_rsa` on disk, it fails with `failed to read ssh key : open : no such file or directory`.  So the URI it gets has `sshauth`, `keyfile` and `known_hosts` filled in from what we can work out.  Override any of them in hypervisors.conf; see `hypervisors.conf.example`.

2. **A remote hypervisor has to be named with an ssh transport.**  `qemu+ssh://user@host/system` (or `+libssh`/`+libssh2`) tells us both how to talk to libvirt and how to get a shell.  `qemu+tcp://` and `qemu+tls://` give us libvirt but no filesystem, so they're refused up front rather than failing halfway through a build.

3. **You need passwordless SSH to the HV** as the user the URI names.  We use your `~/.ssh/config`, so jump hosts and per-host identities work as you'd expect.

    Passwordless `sudo` there is strongly preferred but no longer required: `sudo` runs with `-n`, and if the far side asks for a password you get prompted once and it's remembered for the rest of the run.  Run non-interactively -- from cron, or with stdin redirected -- and there's nobody to ask, so you get an error naming the user and the `NOPASSWD` line to add instead of a hang.

4. **The guest needs a routable address.**  We normally find a new VM by its libvirt NAT lease (`192.168.122.x`), which is only reachable from the HV itself.  When the HV is remote we SSH to the first entry in `ips` instead, so a remote build requires `ips` to be set in provision.conf.  You'll get a clear error rather than a hang if you forget.

5. **Terraform state is kept per-hypervisor.**  The default connection keeps using `/opt/terraform`; anything else gets `/opt/terraform/hv/<name>`, or `/opt/terraform/hv/<mangled uri>` for a hypervisor that came from `--connect` and so has no name.  Sharing one state directory across hypervisors would have terraform believe HV A's resources live on HV B and destroy accordingly.  Override with `tf_dir` in hypervisors.conf, or `--tfdir`.

6. **The whole domain directory is copied to the HV** at the same path, since the guest fetches its payload from there over the NAT network.  It's the whole directory and not just `data.tar.gz` because what else lives in there is decided by whatever provisions your domains, not by this repository -- we're in no position to guess which parts the guest will reach for.  Note that this puts the guest's private key on the hypervisor as well; that's the cost of the hypervisor being the machine the guest fetches from.

    Anything *outside* the domain directory that a guest expects to find on the HV -- `dir=` entries in `mounts.txt` point at hypervisor-side paths, for instance -- is not synced and never was.  Those are yours to provision.

7. **The HV still has to be set up as a hypervisor**: apt-mirror behind nginx, rsyslog listening, the bridge devices, the qemu/kvm group membership.  See UBUNTU DEPS above.  `--connect` points at a hypervisor; it doesn't build one.

### Terraform and things that already exist

Two mechanisms, and you need both:

**`import` blocks** adopt a resource terraform didn't create.  `bin/provision` emits one for the `tf_disks` pool whenever libvirt already has a pool by that name, so the pool is brought under management rather than fought over.

**`ignore_changes`** covers attributes the provider doesn't round-trip.  Importing a pool leaves `target = null` in state whatever the pool is really configured as, so terraform sees `null -> {path=...}`, decides that needs a replacement (storage pools can't be updated in place), and then `prevent_destroy` refuses it -- a standoff no amount of re-running gets out of:

```
Error: Update Not Supported
Storage pools cannot be updated. All changes require replacement.
```

`ignore_changes = [ target ]` on the pool ends it.  `target` is only read when the pool is created, so there's nothing there worth diffing.

Where the pool actually lives is read back from libvirt rather than assumed, so `pool_path` is right even when somebody made the pool somewhere other than `/opt/terraform/disks`.  Set `pool_path` in hypervisors.conf to override.

### Nuking a wedged storage pool

Terraform gets the `tf_disks` pool into states nothing else will get it out of.  `bin/nuke_pool` removes the pool's directory from the hypervisor and then stops, deletes and undefines the pool:

```
bin/nuke_pool
bin/nuke_pool --connect qemu+ssh://root@hv1.example.net/system
```

## UBUNTU DEPS

virt-manager bridge-utils apt-mirror nginx

Expects the HV to be an apt-mirror obviously.

## IF YOU ENCOUNTER MYSTERIOUS 'cannot access image' issues

It's almost certainly that you need to add an override for those dirs in either an apparmor config for libvirt-qemu or selinux.
