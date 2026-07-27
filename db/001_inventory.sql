BEGIN;

-- PostgreSQL 16 provides gen_random_uuid() as a core function. Keeping the
-- schema independent of pgcrypto avoids requiring the optional contrib package.

DO $$
BEGIN
    CREATE TYPE vm_status AS ENUM ('provisioning', 'running', 'stopped', 'failed', 'archived');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS ipam_pools (
    id BIGSERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    subnet CIDR NOT NULL,
    first_host INET NOT NULL,
    last_host INET NOT NULL,
    vlan INTEGER NOT NULL CHECK (vlan BETWEEN 1 AND 4094),
    kea_subnet_id INTEGER UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (family(first_host) = family(last_host)),
    CHECK (first_host <<= subnet),
    CHECK (last_host <<= subnet)
);

CREATE TABLE IF NOT EXISTS ipam_leases (
    pool_id BIGINT NOT NULL REFERENCES ipam_pools(id) ON DELETE RESTRICT,
    ip_address INET NOT NULL,
    allocated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    released_at TIMESTAMPTZ,
    PRIMARY KEY (pool_id, ip_address)
);

CREATE TABLE IF NOT EXISTS vms (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL CHECK (name ~ '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$'),
    owner_name TEXT NOT NULL,
    dataset TEXT NOT NULL,
    mac_address MACADDR NOT NULL,
    ip_address INET NOT NULL,
    pool_id BIGINT NOT NULL REFERENCES ipam_pools(id) ON DELETE RESTRICT,
    vlan INTEGER NOT NULL CHECK (vlan BETWEEN 1 AND 4094),
    template TEXT NOT NULL,
    status vm_status NOT NULL DEFAULT 'provisioning',
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (pool_id, ip_address) REFERENCES ipam_leases(pool_id, ip_address)
);

CREATE UNIQUE INDEX IF NOT EXISTS vms_active_name_idx ON vms (name) WHERE status <> 'archived';
CREATE UNIQUE INDEX IF NOT EXISTS vms_active_dataset_idx ON vms (dataset) WHERE status <> 'archived';
CREATE UNIQUE INDEX IF NOT EXISTS vms_active_mac_address_idx ON vms (mac_address) WHERE status <> 'archived';
CREATE UNIQUE INDEX IF NOT EXISTS vms_active_ip_address_idx ON vms (ip_address) WHERE status <> 'archived';

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS vms_touch_updated_at ON vms;
CREATE TRIGGER vms_touch_updated_at
BEFORE UPDATE ON vms
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION allocate_ip(p_pool_name TEXT) RETURNS TABLE (
    pool_id BIGINT,
    ip_address INET,
    vlan INTEGER,
    kea_subnet_id INTEGER
) AS $$
DECLARE
    p ipam_pools%ROWTYPE;
    candidate INET;
BEGIN
    SELECT * INTO p
      FROM ipam_pools
     WHERE name = p_pool_name
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown IPAM pool: %', p_pool_name;
    END IF;

    SELECT host(set_masklen(network(p.subnet), masklen(p.subnet)) + n)::inet
      INTO candidate
      FROM generate_series(
               (p.first_host - network(p.subnet))::integer,
               (p.last_host - network(p.subnet))::integer
           ) AS n
     WHERE NOT EXISTS (
               SELECT 1
                 FROM ipam_leases l
                WHERE l.pool_id = p.id
                  AND l.ip_address = host(set_masklen(network(p.subnet), masklen(p.subnet)) + n)::inet
                  AND l.released_at IS NULL
           )
     ORDER BY n
     LIMIT 1;

    IF candidate IS NULL THEN
        RAISE EXCEPTION 'IPAM pool exhausted: %', p_pool_name;
    END IF;

    INSERT INTO ipam_leases(pool_id, ip_address)
    VALUES (p.id, candidate)
    ON CONFLICT (pool_id, ip_address)
    DO UPDATE SET allocated_at = CURRENT_TIMESTAMP, released_at = NULL;

    RETURN QUERY SELECT p.id, candidate, p.vlan, p.kea_subnet_id;
END;
$$ LANGUAGE plpgsql;

COMMIT;
