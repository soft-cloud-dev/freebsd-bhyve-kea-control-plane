ALTER TABLE bkcp.operation_steps
    ADD COLUMN input_json TEXT NOT NULL DEFAULT '{}',
    ADD COLUMN postcondition_json TEXT,
    ADD COLUMN postcondition_digest CHAR(64)
        CHECK (postcondition_digest IS NULL OR postcondition_digest ~ '^[0-9a-f]{64}$');

ALTER TABLE bkcp.vm_observations
    ADD COLUMN plan_digest CHAR(64)
        CHECK (plan_digest IS NULL OR plan_digest ~ '^[0-9a-f]{64}$');

ALTER TABLE bkcp.operations DROP CONSTRAINT operations_action_check;
ALTER TABLE bkcp.operations
    ADD CONSTRAINT operations_action_check
    CHECK (action IN ('apply', 'delete', 'reconcile', 'adopt', 'import'));

CREATE INDEX operation_steps_incomplete_idx
    ON bkcp.operation_steps(operation_uuid, sequence)
    WHERE status IN ('pending', 'running', 'failed');
