# Troglodyne Universal Automatic Provisioning

Automatically build and host pretty much any website

## WHY

Until your business is at the scale you need to distribute dynamic operations like statics with a CDN, stuff like openstack or kubernetes is overkill.

This gives you similar ease of orchestration with the supposition you are working with one or a few Hypervisors.
You'd be surprised how well this works for 99% of business purposes.
Even business units at giant corporations can do just fine with this approach.

## How it works

1. Write a configuration file (Config::Simple format) in $DOMAIN/provision.conf which tells us:
    * What IPs/Gw/Resolvers to use for said domain
    * How big the disk oughtta be
    * What base image to use
    * What packages to install
2. Write $DOMAIN/users.yaml describing the users to create. See cloud-init's [documentation](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups) for examples.
2. Ensure tarball backups to restore (if they exist) are in the directory as data.tar.gz.
2. Run `bin/provision $DOMAIN`
3. It is the responsibility of data.tar.gz to have a Makefile in the TLD which sets up all relevant dependencies, loads up DBs, etc as the default target.
4. To set up new sites, have a skeleton site generator to build a blank site tarball.

This all works behind the scenes due to:
1. Terraform's libvirt provider mounting a bogus cdrom with network setup and cloud-config
2. libvirt's virtual networking allowing us to talk to this HV.
3. Spinning off an atd job to actually do the setup when cloud-config is done.

You'll need to have the 'transfer' user set up with at least one working authorized SSH key so we can add more.
Aside from that, clone this in /opt where the 'transfer' user can see it.

From there the host should "Just Work"TM.

See example.test/ for example usage.

All the relevant resources will be stored in /vms on the HV.
