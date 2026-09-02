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
    * libvirt\_uri: Connection string for the hypervisor to build on.  Defaults to `qemu:///system`, i.e. this machine.  Anything but the local machine has to use an ssh transport, e.g. `qemu+ssh://root@hv1.example.net/system`.  See "PROVISIONING A REMOTE HYPERVISOR" below.
    * bridge\_device / virbr\_device: Skip autodetection and name the outbound bridge / libvirt NAT bridge outright.  Handy when the HV has several and `brctl show | tail -n1` guesses wrong.
    * pool\_path: Where the `tf_disks` storage pool lives on the HV.  Defaults to `/opt/terraform/disks`.
    * domain\_dir: Where the per-domain directories live, on both this machine and the HV.  Defaults to `/opt/domains`; `--domaindir` overrides it.
    * tf\_dir: Where terraform's config and state live.  Defaults to `/opt/terraform` for the local HV and `/opt/terraform/hv/<mangled uri>` for any other; `--tfdir` overrides it.

    The last five describe the *hypervisor*, not the domain, so they're read from the provision.conf of the domain you invoked.  A `depends_on` domain's copy of them is ignored -- both domains land on the same hypervisor by definition.
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

By default the hypervisor is the machine you run `bin/provision` on.  To build somewhere else, hand it any connection string libvirt understands, either on the command line:

```
bin/provision --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/destroy   --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/snapshot  --connect qemu+ssh://root@hv1.example.net/system mysite.test
bin/restore   --connect qemu+ssh://root@hv1.example.net/system --latest mysite.test
```

...or per-domain in `$DOMAIN/provision.conf`, which every tool will pick up on its own:

```
libvirt_uri=qemu+ssh://root@hv1.example.net/system
```

`--connect` beats the config file when both are set.

### What that actually does

The URI is handed to terraform's libvirt provider and used for every libvirt call we make, which all go through `Sys::Virt` -- no `virsh`, so libvirt's own transports do the work.  Beyond that, a fair amount of what this tool does is not libvirt at all -- discovering the bridge devices, dropping `virtiofs-better` in `/usr/libexec`, writing the rsyslog collector config, putting the domain directory somewhere the guest can fetch it from -- and all of it has to happen *on the hypervisor*.  So for a remote URI we also get a shell there over SSH and do it remotely.

That means:

1. **A remote hypervisor has to be named with an ssh transport.**  `qemu+ssh://user@host/system` (or `+libssh`/`+libssh2`) tells us both how to talk to libvirt and how to get a shell.  `qemu+tcp://` and `qemu+tls://` give us libvirt but no filesystem, so they're refused up front rather than failing halfway through a build.

2. **You need passwordless SSH to the HV** as the user the URI names, with passwordless `sudo`.  We use your `~/.ssh/config`, so jump hosts and per-host identities work as you'd expect.

3. **The guest needs a routable address.**  We normally find a new VM by its libvirt NAT lease (`192.168.122.x`), which is only reachable from the HV itself.  When the HV is remote we SSH to the first entry in `ips` instead, so a remote build requires `ips` to be set in provision.conf.  You'll get a clear error rather than a hang if you forget.

4. **Terraform state is kept per-hypervisor.**  The default connection keeps using `/opt/terraform`; anything else gets `/opt/terraform/hv/<mangled uri>`.  Sharing one state directory across hypervisors would have terraform believe HV A's resources live on HV B and destroy accordingly.  Override with `--tfdir` if you want it somewhere specific.

5. **The whole domain directory is copied to the HV** at the same path, since the guest fetches its payload from there over the NAT network.  It's the whole directory and not just `data.tar.gz` because what else lives in there is decided by whatever provisions your domains, not by this repository -- we're in no position to guess which parts the guest will reach for.  Note that this puts the guest's private key on the hypervisor as well; that's the cost of the hypervisor being the machine the guest fetches from.

    Anything *outside* the domain directory that a guest expects to find on the HV -- `dir=` entries in `mounts.txt` point at hypervisor-side paths, for instance -- is not synced and never was.  Those are yours to provision.

6. **The HV still has to be set up as a hypervisor**: apt-mirror behind nginx, rsyslog listening, the bridge devices, the qemu/kvm group membership.  See UBUNTU DEPS above.  `--connect` points at a hypervisor; it doesn't build one.

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
