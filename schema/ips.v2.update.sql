-- NICs: a guest can have more than one static adapter, each on its own bridge
-- with its own pool, so an address of the guests bin is recorded with the
-- bridge whose pool it came out of, and a domain can hold one address on each
-- bridge.  SQLite cannot change the UNIQUE in place, so the table is made again
-- and filled from the old one.  Trog::SQLite runs this once, in a transaction.
CREATE TABLE ips_by_nic (
    ip     TEXT PRIMARY KEY NOT NULL,
    domain TEXT NOT NULL,
    -- What put it here: 'domain' for a guest, 'reserved' for the hypervisor and
    -- the gateway, which are nobody's to hand out.
    kind   TEXT NOT NULL DEFAULT 'domain',
    -- The bin of the ip_pool that the address came out of.
    bin    TEXT NOT NULL DEFAULT 'guests',
    -- The bridge of the static adapter whose pool the address came out of, for
    -- the guests bin.  Empty for the other bins, and for a row from before this
    -- column, whose bridge nobody recorded: Provisioner::IPPool::assign gives it
    -- the bridge whose pool holds its address, the first time that the domain
    -- asks for an address on that bridge.
    nic    TEXT NOT NULL DEFAULT '',
    -- 1 for the address of the guest, on the first of static_nics, which ipmap
    -- names, and for an address of another bin.  A row from before this column
    -- was the address of its guest.
    main   INTEGER NOT NULL DEFAULT 1,
    noted  TEXT NOT NULL DEFAULT (datetime('now')),
    -- One address per name in each bin, on each bridge.  A domain that already
    -- has one is answered with it rather than given a second, which is what
    -- makes assigning idempotent.
    UNIQUE (domain, bin, nic)
);

INSERT INTO ips_by_nic (ip, domain, kind, bin, noted) SELECT ip, domain, kind, bin, noted FROM ips;
DROP TABLE ips;
ALTER TABLE ips_by_nic RENAME TO ips;
