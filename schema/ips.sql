-- Which address belongs to what, and the reason it is a database rather than a
-- section of ipmap.cfg: two provisions running at once both read the file, both
-- pick the same free address, and the second write wins.  A primary key and a
-- transaction make that impossible instead of unlikely.
--
-- Provisioner::IPPool adds the bin column to a database made before it existed.
CREATE TABLE IF NOT EXISTS ips (
    ip     TEXT PRIMARY KEY NOT NULL,
    domain TEXT NOT NULL,
    -- What put it here: 'domain' for a guest, 'reserved' for the hypervisor and
    -- the gateway, which are nobody's to hand out.
    kind   TEXT NOT NULL DEFAULT 'domain',
    -- The bin of the ip_pool that the address came out of.
    bin    TEXT NOT NULL DEFAULT 'guests',
    noted  TEXT NOT NULL DEFAULT (datetime('now')),
    -- One address per name in each bin.  A domain that already has one is
    -- answered with it rather than given a second, which is what makes
    -- assigning idempotent.
    UNIQUE (domain, bin)
);

-- Which sources have been interrogated, so that a seed which failed partway is
-- retried rather than remembered as done.  Inferring it from "are there any
-- rows at all" meant one hypervisor answering and another refusing left a
-- database that looked seeded forever and was missing every guest on the second.
CREATE TABLE IF NOT EXISTS seeded (
    source TEXT PRIMARY KEY NOT NULL,
    at     TEXT NOT NULL DEFAULT (datetime('now'))
);
