package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

func (r *Repository) PrepareExecutableReconcile(ctx context.Context, site config.Site, name string) (state.PreparedApply, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("begin reconcile preparation: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, resourceLockKey(site.ControlPlaneID, name)); err != nil {
		return state.PreparedApply{}, fmt.Errorf("lock resource: %w", err)
	}
	var resourceUUID string
	var generation uint64
	var specBytes []byte
	if err := tx.QueryRow(ctx, `
SELECT r.uuid::text,r.current_generation,s.normalized_spec
FROM bkcp.resources r
JOIN bkcp.vm_specs s ON s.resource_uuid=r.uuid AND s.generation=r.current_generation
WHERE r.name=$1 AND r.archived_at IS NULL`, name).Scan(&resourceUUID, &generation, &specBytes); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return state.PreparedApply{}, state.ErrNotFound
		}
		return state.PreparedApply{}, fmt.Errorf("load reconcile declaration: %w", err)
	}
	var normalized config.NormalizedVM
	if err := json.Unmarshal(specBytes, &normalized); err != nil {
		return state.PreparedApply{}, fmt.Errorf("decode reconcile declaration: %w", err)
	}
	allocated, err := loadAllocationTx(ctx, tx, resourceUUID)
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("load reconcile allocation: %w", err)
	}
	executable, err := planner.BuildExecutableReconcile(site, generation, manifestFromNormalized(normalized), plannerAllocation(allocated))
	if err != nil {
		return state.PreparedApply{}, err
	}
	operation, created, err := persistExecutableOperation(ctx, tx, resourceUUID, executable)
	if err != nil {
		return state.PreparedApply{}, err
	}
	if !created {
		if _, err := tx.Exec(ctx, `UPDATE bkcp.operations SET status='pending',completed_at=NULL,error_code=NULL,error_detail=NULL,updated_at=CURRENT_TIMESTAMP WHERE uuid=$1 AND status <> 'running'`, operation.UUID); err != nil {
			return state.PreparedApply{}, fmt.Errorf("reset reconcile operation: %w", err)
		}
		if _, err := tx.Exec(ctx, `UPDATE bkcp.operation_steps SET status='pending',started_at=NULL,completed_at=NULL,postcondition_json=NULL,postcondition_digest=NULL,error_code=NULL,error_detail=NULL WHERE operation_uuid=$1`, operation.UUID); err != nil {
			return state.PreparedApply{}, fmt.Errorf("reset reconcile steps: %w", err)
		}
		operation.Status = "pending"
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_effective(resource_uuid,state,current_plan_digest)
VALUES ($1,'applying',$2)
ON CONFLICT (resource_uuid) DO UPDATE SET state='applying',reason_code=NULL,reason_detail=NULL,current_plan_digest=EXCLUDED.current_plan_digest,updated_at=CURRENT_TIMESTAMP`, resourceUUID, executable.Plan.PlanDigest); err != nil {
		return state.PreparedApply{}, fmt.Errorf("mark reconciling: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return state.PreparedApply{}, fmt.Errorf("commit reconcile preparation: %w", err)
	}
	return state.PreparedApply{Resource: state.ResourceSummary{UUID: resourceUUID, Name: name, Managed: true, Generation: generation, EffectiveState: "applying", OperationStatus: operation.Status}, Plan: executable.Plan, Operation: operation, Created: created}, nil
}
