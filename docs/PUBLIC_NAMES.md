# Public names

A public name is a name under which the internet reaches a guest through a
proxy, such as an edge guest on the VPN.  `nginx.public_names` maps each public
name to the vhost that answers for it.  `perldoc Provisioner::Recipe::nginx`
has the details, under "Names that reach the guest through a proxy".

```yaml
staging.ours.example:
    nginx:
        public_names:
            www.ours.example: staging.ours.example
            shop.customer.example: staging.ours.example
```

A public name needs two things: a DNS record that points at the guest, and a
certificate that names it.  Who can write the record decides how the name gets
both.  There are four cases.

| Where the name is | What the build does |
|---|---|
| In the zone of the domain | The registrar publishes it, and letsencrypt certifies it, as any other name of the domain. |
| In a zone that a registrar account lists | The build publishes it in that zone, and certifies it through the same account. |
| In a zone delegated to our nameservers | The build publishes it through the pdns guest that holds the zone, and certifies it. |
| Anywhere else | The build publishes and certifies `public.VHOST` in its place.  The vhost answers for the name too. |

In a zone other than the zone of the domain, the apex of the zone gets an `A`
record at the address of the domain.  Every other name gets a `CNAME` of the
domain.  A name that holds a `CNAME` gets no `A` record, and a name that holds
an `A` record gets no `CNAME`.  The build fails there instead.  Remove the old
record at the provider first.

## A zone at a registrar that we have an account with

List the zone under the account in `_base`, and rebuild the guest:

```yaml
_base:
    registrar:
        accounts:
            ours-easydns:
                type: easydns
                user: "secret:registrar/ours/username"
                key:  "secret:registrar/ours/password"
                zones: [ ours.example, other.example ]
```

The provider must take a token and a user name, as easydns does.  Issue #425
has what other providers, such as route53, need.

## A zone that the owner delegates to us

The owner can keep the zone at a registrar that we have no account with.
Then the owner points the `NS` records of the zone at our nameservers, and a
pdns guest of this installation holds the zone.

1. Add the zone to an account in `_base` that names the pdns guest as its
   `authority`:

   ```yaml
   _base:
       registrar:
           accounts:
               ours-pdns:
                   authority: ns.ours.example
                   zones: [ customer.example ]
   ```

2. Rebuild the pdns guest.  It builds the zone, with an `SOA` record and `NS`
   records for `ns1` of the guest and for each of the `nameservers` of
   `_global`.  A zone that its database holds already stays as it is.

3. Run `bin/check_delegation customer.example`.  It prints the nameservers
   that the zone must be delegated to.  Give them to the owner, who sets them
   as the `NS` records of the zone at their registrar.  The owner removes
   every other `NS` record, because the CA can ask any of them for a
   challenge.

4. Run `bin/check_delegation customer.example` again until it says that the
   zone is delegated here, and exits 0.  A change of `NS` records can take a
   day to reach every resolver.

5. Add the public name to `nginx.public_names` of the guest that serves it, and
   rebuild that guest.  The guest gets a token from the pdns guest that writes
   only its own names in the zone, and their challenges.

Several guests can serve names in one zone.  `bin/destroy` of a guest removes
its token, and the zone stays.  To give up the zone, remove it from the
account.  The pdns guest keeps the zone in its database after that, so delete
it there with `pdnsutil zone delete customer.example`.

## A name in a zone that we cannot write

The build cannot certify such a name, because no DNS-01 challenge can answer
for it.  So it publishes and certifies `public.VHOST` in its place, and the
vhost answers for both names.  You can then test the path through the proxy at
`public.VHOST` before the owner of the name changes anything.

To serve the name itself, the owner can delegate its zone to us, as in the
section above.  The other way is a claim by an HTTP-01 challenge, after the
owner points the `A` record of the name at the edge.  That claim comes with the
edge guest, in step 5 of issue #414.
