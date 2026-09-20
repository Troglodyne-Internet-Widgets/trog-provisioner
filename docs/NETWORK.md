# The network model

This document says what the provisioner assumes about the networks a guest is
on.  Every address in the configuration means something in this model, so read
it before you choose a pool or a gateway.

The model is the one that almost every virtualized environment uses: a
hypervisor with one network that it shares with the world, and one private
network that only it and its guests can use.

## A libvirt hypervisor

A libvirt hypervisor has two bridges, and each guest has an interface on each.

The **primary bridge** (`bridge_device`, the guest's `ens4`) is on the same
subnet as the hypervisor's own primary interface.  A guest's **static
address** is an address on this subnet.  It is the address that other
machines use to reach the guest.

- If the hypervisor is in a data center and has a public address, this subnet
  is public, so a static address is a public address.
- If the hypervisor is in a home or an office, this subnet is the network
  behind your gateway.  A static address is then "public" to every machine on
  that network, and private to the internet.

The **NAT bridge** (`virbr_device`, the guest's `ens3`) is libvirt's own
network, `192.168.122.0/24` by default.  Only the hypervisor and its guests can
use it.  A guest gets a DHCP lease on it at first boot.  The provisioner finds
a new guest on a local hypervisor by that lease, and a guest fetches its
payload over it when this machine is the hypervisor.

## What the configuration names

In the `_global` of `_base` in `recipes.yaml`:

- `ip_pool` lists the static addresses that guests can get.  They must be on
  the subnet of the primary bridge.  Keep them out of any range that a DHCP
  server on that network hands out.
- `gateway` is the gateway of that subnet.
- `transfer_ip` is the address of this machine that a guest fetches its payload
  from.  Set it only when this machine has more than one route to the guest, or
  when the guest has no address yet to route to.

`bin/assign_ip` prints or assigns the static address of a domain.  Assignments
are kept in `ips.db`: see `perldoc Provisioner::IPPool`.

## A remote hypervisor

When the hypervisor is not this machine, the NAT lease of a guest is reachable
only from the hypervisor.  So the provisioner reaches a guest on a remote
hypervisor by its static address, and a remote build needs one.

## A cloud

An OpenStack cloud gives a guest its address when it creates the guest, and
the guest is reached by a floating IP.  The pool is not used, and there is no
NAT bridge of ours.  A cloud can have more than one network that a guest is
on, and the provisioner does not choose between them yet: see issue #203.
