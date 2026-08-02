CREATE TABLE bkcp.resources (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE CHECK (name ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
    kind TEXT NOT NULL DEFAULT 'vm' CHECK (kind = 'vm'),
    managed BOOLEAN NOT NULL DEFAULT TRUE,
    current_generation BIGINT CHECK (current_generation IS NULL OR current_generation > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    archived_at TIMESTAMPTZ
);

CREATE TABLE bkcp.vm_specs (
    resource_uuid UUID NOT NULL REFERENCES bkcp.resources(uuid) ON DELETE RESTRICT,
    generation BIGINT NOT NULL CHECK (generation > 0),
    normalized_spec JSONB NOT NULL,
    spec_digest CHAR(64) NOT NULL CHECK (spec_digest ~ '^[0-9a-f]{64}$'),
    desired_presence TEXT NOT NULL DEFAULT 'present' CHECK (desired_presence IN ('present', 'absent')),
    desired_power TEXT NOT NULL CHECK (desired_power IN ('running', 'stopped')),
    source_path TEXT,
    declared_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (resource_uuid, generation),
    UNIQUE (resource_uuid, generation, spec_digest)
);

ALTER TABLE bkcp.resources
    ADD CONSTRAINT resources_current_spec_fk
    FOREIGN KEY (uuid, current_generation)
    REFERENCES bkcp.vm_specs(resource_uuid, generation)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE bkcp.vm_allocations (
    resource_uuid UUID PRIMARY KEY REFERENCES bkcp.resources(uuid) ON DELETE RESTRICT,
    pool_name TEXT NOT NULL,
    pool_id BIGINT,
    ip_address INET,
    mac_address MACADDR,
    dataset_name TEXT,
    zvol_name TEXT,
    kea_subnet_id INTEGER,
    image_name TEXT NOT NULL,
    image_digest CHAR(64) CHECK (image_digest IS NULL OR image_digest ~ '^[0-9a-f]{64}$'),
    allocation_generation BIGINT NOT NULL CHECK (allocation_generation > 0),
    allocated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    released_at TIMESTAMPTZ,
    UNIQUE (ip_address),
    UNIQUE (mac_address),
    UNIQUE (dataset_name),
    UNIQUE (zvol_name)
);

CREATE TABLE bkcp.vm_observations (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_uuid UUID NOT NULL REFERENCES bkcp.resources(uuid) ON DELETE RESTRICT,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    observer_version TEXT NOT NULL,
    vm_state TEXT NOT NULL CHECK (vm_state IN ('unknown', 'unavailable', 'absent', 'present')),
    storage_state TEXT NOT NULL CHECK (storage_state IN ('unknown', 'unavailable', 'absent', 'present')),
    kea_state TEXT NOT NULL CHECK (kea_state IN ('unknown', 'unavailable', 'absent', 'present')),
    seed_state TEXT NOT NULL CHECK (seed_state IN ('unknown', 'unavailable', 'absent', 'present')),
    power_state TEXT NOT NULL CHECK (power_state IN ('unknown', 'unavailable', 'absent', 'running', 'stopped')),
    observed JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_code TEXT,
    error_detail TEXT CHECK (error_detail IS NULL OR length(error_detail) <= 4096)
);

CREATE INDEX vm_observations_resource_time_idx
    ON bkcp.vm_observations(resource_uuid, collected_at DESC, uuid DESC);

CREATE TABLE bkcp.vm_effective (
    resource_uuid UUID PRIMARY KEY REFERENCES bkcp.resources(uuid) ON DELETE RESTRICT,
    state TEXT NOT NULL CHECK (state IN ('pending', 'applying', 'converged', 'degraded', 'drifted', 'deleting', 'absent', 'blocked')),
    reason_code TEXT,
    reason_detail TEXT CHECK (reason_detail IS NULL OR length(reason_detail) <= 4096),
    current_plan_digest CHAR(64) CHECK (current_plan_digest IS NULL OR current_plan_digest ~ '^[0-9a-f]{64}$'),
    latest_observation_uuid UUID REFERENCES bkcp.vm_observations(uuid) ON DELETE SET NULL,
    last_successful_reconciliation_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE bkcp.operations (
    uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_uuid UUID NOT NULL,
    generation BIGINT NOT NULL CHECK (generation > 0),
    action TEXT NOT NULL CHECK (action IN ('apply', 'delete', 'adopt', 'import')),
    spec_digest CHAR(64) NOT NULL CHECK (spec_digest ~ '^[0-9a-f]{64}$'),
    plan_digest CHAR(64) NOT NULL CHECK (plan_digest ~ '^[0-9a-f]{64}$'),
    idempotency_key CHAR(64) NOT NULL UNIQUE CHECK (idempotency_key ~ '^[0-9a-f]{64}$'),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'blocked', 'cancelled')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    error_code TEXT,
    error_detail TEXT CHECK (error_detail IS NULL OR length(error_detail) <= 4096),
    FOREIGN KEY (resource_uuid, generation)
        REFERENCES bkcp.vm_specs(resource_uuid, generation)
        ON DELETE RESTRICT
);

CREATE INDEX operations_resource_created_idx
    ON bkcp.operations(resource_uuid, created_at DESC, uuid DESC);
CREATE INDEX operations_incomplete_idx
    ON bkcp.operations(resource_uuid, created_at DESC)
    WHERE status IN ('pending', 'running', 'failed', 'blocked');

CREATE TABLE bkcp.operation_steps (
    operation_uuid UUID NOT NULL REFERENCES bkcp.operations(uuid) ON DELETE CASCADE,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    driver TEXT NOT NULL,
    action TEXT NOT NULL,
    input_digest CHAR(64) NOT NULL CHECK (input_digest ~ '^[0-9a-f]{64}$'),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'skipped')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error_code TEXT,
    error_detail TEXT CHECK (error_detail IS NULL OR length(error_detail) <= 4096),
    PRIMARY KEY (operation_uuid, sequence),
    UNIQUE (operation_uuid, driver, action, input_digest)
);
