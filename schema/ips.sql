-- Which address belongs to what, and the reason it is a database rather than a
-- section of ipmap.cfg: two provisions running at once both read the file, both
-- pick the same free address, and the second write wins.  A primary key and a
-- transaction make that impossible instead of unlikely.
CREATE TABLE IF NOT EXISTS ips (
    ip     TEXT PRIMARY KEY NOT NULL,
    -- One address per name.  A domain that already has one is answered with it
    -- rather than given a second, which is what makes assigning idempotent.
    domain TEXT NOT NULL UNIQUE,
    -- What put it here: 'domain' for a guest, 'reserved' for the hypervisor and
    -- the gateway, which are nobody's to hand out.
    kind   TEXT NOT NULL DEFAULT 'domain',
    noted  TEXT NOT NULL DEFAULT (datetime('now'))
);
