-- Enum tables: the kind, the bin and the bridge of an address are each a name
-- out of a short list, so each name is stored once, in a table of its own, and
-- a row of addresses refers to it by id.  The table of rows is addresses, and
-- ips becomes a view of it that has the columns that ips had, with triggers
-- that write through it.  So the code that reads and writes ips does not change,
-- but for one thing: SQLite counts no row that a trigger changes, so a write
-- through ips reports 0 rows.  Provisioner::IPPool counts the rows of ips
-- instead where it needs the number.  Trog::SQLite runs this once, in a
-- transaction.

-- The kinds are a closed list, so a kind that is not here is refused.
CREATE TABLE address_kinds (
    id   INTEGER PRIMARY KEY,
    -- 'domain' for a guest, 'reserved' for the hypervisor, a gateway and
    -- anything else that answered on the network, which are nobody's to hand
    -- out.
    name TEXT NOT NULL UNIQUE
);
INSERT INTO address_kinds (name) VALUES ('domain'), ('reserved');

-- The bins of the ip_pool, which the configuration names, so a new name is
-- added the first time that an address of it is written.
CREATE TABLE address_bins (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- The bridges of the static adapters, which hypervisors.conf names, so a new
-- name is added as a bin is.  The empty name is for an address of another bin,
-- and for one from before the bridge was recorded.
CREATE TABLE address_nics (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE addresses (
    ip          TEXT PRIMARY KEY NOT NULL,
    domain      TEXT NOT NULL,
    kind_id     INTEGER NOT NULL REFERENCES address_kinds (id) ON DELETE RESTRICT,
    -- The bin of the ip_pool that the address came out of.
    bin_id      INTEGER NOT NULL REFERENCES address_bins (id) ON DELETE RESTRICT,
    -- The bridge of the static adapter whose pool the address came out of, for
    -- the guests bin.
    nic_id      INTEGER NOT NULL REFERENCES address_nics (id) ON DELETE RESTRICT,
    -- 1 for the address of the guest, on the first of static_nics, which ipmap
    -- names, and for an address of another bin.
    main        INTEGER NOT NULL DEFAULT 1,
    assigned_at TEXT NOT NULL DEFAULT (datetime('now')),
    -- One address per name in each bin, on each bridge.  A domain that already
    -- has one is answered with it rather than given a second, which is what
    -- makes assigning idempotent.
    UNIQUE (domain, bin_id, nic_id)
);

INSERT INTO address_bins (name) SELECT DISTINCT bin FROM ips;
INSERT INTO address_nics (name) SELECT DISTINCT nic FROM ips;
INSERT INTO address_kinds (name) SELECT DISTINCT kind FROM ips WHERE kind NOT IN (SELECT name FROM address_kinds);

INSERT INTO addresses (ip, domain, kind_id, bin_id, nic_id, main, assigned_at)
    SELECT i.ip, i.domain, k.id, b.id, n.id, i.main, i.noted
    FROM ips AS i
    JOIN address_kinds AS k ON k.name = i.kind
    JOIN address_bins  AS b ON b.name = i.bin
    JOIN address_nics  AS n ON n.name = i.nic;

DROP TABLE ips;

CREATE VIEW ips AS
    SELECT a.ip, a.domain, k.name AS kind, b.name AS bin, n.name AS nic, a.main, a.assigned_at
    FROM addresses AS a
    JOIN address_kinds AS k ON k.id = a.kind_id
    JOIN address_bins  AS b ON b.id = a.bin_id
    JOIN address_nics  AS n ON n.id = a.nic_id;

-- A view has no defaults, so each column that the table of ips had a default
-- for gets it here.  A conflict clause on the INSERT that fires this, such as
-- OR IGNORE, applies to the INSERT into addresses too.
CREATE TRIGGER ips_insert INSTEAD OF INSERT ON ips
BEGIN
    SELECT RAISE(ABORT, 'ips: no such kind') WHERE NOT EXISTS (SELECT 1 FROM address_kinds WHERE name = coalesce(NEW.kind, 'domain'));
    INSERT OR IGNORE INTO address_bins (name) VALUES (coalesce(NEW.bin, 'guests'));
    INSERT OR IGNORE INTO address_nics (name) VALUES (coalesce(NEW.nic, ''));
    INSERT INTO addresses (ip, domain, kind_id, bin_id, nic_id, main, assigned_at)
        VALUES (
            NEW.ip,
            NEW.domain,
            (SELECT id FROM address_kinds WHERE name = coalesce(NEW.kind, 'domain')),
            (SELECT id FROM address_bins  WHERE name = coalesce(NEW.bin, 'guests')),
            (SELECT id FROM address_nics  WHERE name = coalesce(NEW.nic, '')),
            coalesce(NEW.main, 1),
            coalesce(NEW.assigned_at, datetime('now'))
        );
END;

CREATE TRIGGER ips_update INSTEAD OF UPDATE ON ips
BEGIN
    SELECT RAISE(ABORT, 'ips: no such kind') WHERE NOT EXISTS (SELECT 1 FROM address_kinds WHERE name = NEW.kind);
    INSERT OR IGNORE INTO address_bins (name) VALUES (NEW.bin);
    INSERT OR IGNORE INTO address_nics (name) VALUES (NEW.nic);
    UPDATE addresses SET
        ip          = NEW.ip,
        domain      = NEW.domain,
        kind_id     = (SELECT id FROM address_kinds WHERE name = NEW.kind),
        bin_id      = (SELECT id FROM address_bins  WHERE name = NEW.bin),
        nic_id      = (SELECT id FROM address_nics  WHERE name = NEW.nic),
        main        = NEW.main,
        assigned_at = NEW.assigned_at
    WHERE ip = OLD.ip;
END;

CREATE TRIGGER ips_delete INSTEAD OF DELETE ON ips
BEGIN
    DELETE FROM addresses WHERE ip = OLD.ip;
END;
