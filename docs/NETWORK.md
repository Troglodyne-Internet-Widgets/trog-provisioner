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
  server on that network hands out.  Its `bins` name other parts of the pool,
  such as the addresses of VPN clients.  Each bin hands out only its own
  addresses: see `BINS` in `perldoc Provisioner::IPPool`.
- `gateway` is the gateway of that subnet.
- `transfer_ip` is the address of this machine that a guest fetches its payload
  from.  Set it only when this machine has more than one route to the guest, or
  when the guest has no address yet to route to.

`bin/assign_ip` prints or assigns the static address of a domain.  Assignments
are kept in `ips.db`: see `perldoc Provisioner::IPPool`.

## Static addresses for VPN clients

A bin can name a guest in `via`.  Its addresses are then reachable only
through that guest, for example the clients of the openvpn server on it:

```yaml
ip_pool:
    cidr: 192.0.2.0/24
    bins:
        vpnclients:
            cidr: 10.8.0.128/25
            via: vpn.$domain
```

Here `192.0.2.0/24` is the subnet of the primary bridge, which the guests get
their static addresses from.  `10.8.0.0/24` is the tunnel subnet of the openvpn
server, its default `subnet` and `netmask`, and the bin is its top half.

A domain whose `openvpnclient` names `issue_from: vpn.$domain` gets an address
from that bin when it is built, and the server gives that address to it at
each connect.  Each guest gets a route to the bin through `vpn.$domain` at
first boot.  So the guests reach the client at its address, and see that
address when the client connects to them.

The server can also give an address from the bin to a client by hand, for
example to a laptop.  So the provisioner asks `vpn.$domain` which addresses its
clients have.  It asks before it gives a domain a new address from the bin.  It
reserves each address that `ips.db` does not know.  If `vpn.$domain` is not up,
the build of that domain stops.  `bin/list_ip_pool` also asks.  If it cannot
ask, it warns.

These must be true:

- The bin is inside the `subnet` of the openvpn server, at its top end.  The
  first two addresses of the subnet are the network and the server, so the bin
  cannot hold them.
- No other bin has an address in that `subnet`.  So two openvpn servers with
  bins need two different values of `subnet`, because both have the same
  default.
- Each host that is not a guest of this installation, and that talks to a
  client, needs the same route.  Add it on the router of the network, or on the
  host itself.  This machine needs it before a client can reach it by ssh.
- A guest that was built before the bin had `via` gets the route when you
  build it again.

`perldoc Provisioner::Recipe::openvpn` has the details, under "Static
addresses".

## A remote hypervisor

When the hypervisor is not this machine, the NAT lease of a guest is reachable
only from the hypervisor.  So the provisioner reaches a guest on a remote
hypervisor by its static address, and a remote build needs one.

## A cloud

An OpenStack cloud gives a guest its address when it creates the guest, and
the guest is reached by a floating IP.  The pool is not used, and there is no
NAT bridge of ours.  A cloud can have more than one network that a guest is
on, and the provisioner does not choose between them yet: see issue #203.

A Linode gets a public address when Linode creates it, and the guest is
reached there.  The pool is not used here either.  A guest with `private_ip`
also has an address on Linode's private network, which is not the one we
reach it at.
