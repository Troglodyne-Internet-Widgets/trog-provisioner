-- Bins: the address of a domain is recorded with the bin of the ip_pool it came
-- out of, and a domain can hold one address in each bin.  SQLite cannot drop
-- the UNIQUE on domain in place, so the table is made again and filled from the
-- old one.  Trog::SQLite runs this once, in a transaction.
CREATE TABLE ips_binned (
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

INSERT INTO ips_binned (ip, domain, kind, noted) SELECT ip, domain, kind, noted FROM ips;
DROP TABLE ips;
ALTER TABLE ips_binned RENAME TO ips;
