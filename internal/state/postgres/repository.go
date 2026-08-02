package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

type Repository struct{ pool *pgxpool.Pool }

func Open(ctx context.Context, dsn string) (*Repository, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("configure PostgreSQL pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect PostgreSQL: %w", err)
	}
	return &Repository{pool: pool}, nil
}

func (r *Repository) Close() { r.pool.Close() }

func IsSchemaMissing(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && (pgErr.Code == "42P01" || pgErr.Code == "3F000")
}

func (r *Repository) PrepareApply(ctx context.Context, controlPlaneID, sourcePath string, manifest config.VMManifest) (state.PreparedApply, error) {
	if err := manifest.Validate(); err != nil {
		return state.PreparedApply{}, err
	}
	specDigest, err := manifest.Digest()
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("digest manifest: %w", err)
	}
	normalized := manifest.Normalize()
	specJSON, err := json.Marshal(normalized)
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("encode normalized manifest: %w", err)
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("begin prepare transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	lockKey := controlPlaneID + "\x00vm\x00" + normalized.Name
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, lockKey); err != nil {
		return state.PreparedApply{}, fmt.Errorf("lock resource: %w", err)
	}
	var resourceUUID string
	var currentGeneration *int64
	if err := tx.QueryRow(ctx, `
INSERT INTO bkcp.resources(name, kind, managed)
VALUES ($1, 'vm', TRUE)
ON CONFLICT (name) DO UPDATE SET updated_at = CURRENT_TIMESTAMP
RETURNING uuid::text, current_generation`, normalized.Name).Scan(&resourceUUID, &currentGeneration); err != nil {
		return state.PreparedApply{}, fmt.Errorf("load resource: %w", err)
	}
	generation := uint64(1)
	declarationChanged := true
	if currentGeneration != nil {
		generation = uint64(*currentGeneration)
		var currentDigest string
		if err := tx.QueryRow(ctx, `SELECT spec_digest FROM bkcp.vm_specs WHERE resource_uuid = $1 AND generation = $2`, resourceUUID, *currentGeneration).Scan(&currentDigest); err != nil {
			return state.PreparedApply{}, fmt.Errorf("load current declaration: %w", err)
		}
		if currentDigest == specDigest {
			declarationChanged = false
		} else {
			generation++
		}
	}
	if declarationChanged {
		if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_specs(resource_uuid, generation, normalized_spec, spec_digest, desired_presence, desired_power, source_path)
VALUES ($1, $2, $3, $4, 'present', $5, NULLIF($6, ''))`, resourceUUID, generation, specJSON, specDigest, normalized.DesiredPower, sourcePath); err != nil {
			return state.PreparedApply{}, fmt.Errorf("insert declaration: %w", err)
		}
		if _, err := tx.Exec(ctx, `UPDATE bkcp.resources SET current_generation = $2, updated_at = CURRENT_TIMESTAMP WHERE uuid = $1`, resourceUUID, generation); err != nil {
			return state.PreparedApply{}, fmt.Errorf("advance generation: %w", err)
		}
	}
	plan, err := planner.BuildApply(controlPlaneID, generation, manifest)
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("build plan: %w", err)
	}
	var operation state.Operation
	var created bool
	if err := tx.QueryRow(ctx, `
WITH inserted AS (
    INSERT INTO bkcp.operations(resource_uuid, generation, action, spec_digest, plan_digest, idempotency_key)
    VALUES ($1, $2, 'apply', $3, $4, $5)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING uuid::text, resource_uuid::text, generation, action, spec_digest, plan_digest, idempotency_key, status, attempts, created_at, started_at, completed_at, COALESCE(error_code, ''), COALESCE(error_detail, ''), TRUE
)
SELECT * FROM inserted
UNION ALL
SELECT uuid::text, resource_uuid::text, generation, action, spec_digest, plan_digest, idempotency_key, status, attempts, created_at, started_at, completed_at, COALESCE(error_code, ''), COALESCE(error_detail, ''), FALSE
FROM bkcp.operations WHERE idempotency_key = $5
LIMIT 1`, resourceUUID, generation, plan.SpecDigest, plan.PlanDigest, plan.IdempotencyKey).Scan(
		&operation.UUID, &operation.ResourceUUID, &operation.Generation, &operation.Action, &operation.SpecDigest,
		&operation.PlanDigest, &operation.IdempotencyKey, &operation.Status, &operation.Attempts, &operation.CreatedAt,
		&operation.StartedAt, &operation.CompletedAt, &operation.ErrorCode, &operation.ErrorDetail, &created,
	); err != nil {
		return state.PreparedApply{}, fmt.Errorf("persist operation: %w", err)
	}
	for _, step := range plan.Steps {
		if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.operation_steps(operation_uuid, sequence, driver, action, input_digest)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (operation_uuid, sequence) DO NOTHING`, operation.UUID, step.Sequence, step.Driver, step.Action, step.InputDigest); err != nil {
			return state.PreparedApply{}, fmt.Errorf("persist operation step %d: %w", step.Sequence, err)
		}
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_effective(resource_uuid, state, current_plan_digest)
VALUES ($1, 'pending', $2)
ON CONFLICT (resource_uuid) DO UPDATE
SET state = CASE WHEN bkcp.vm_effective.state = 'converged' AND bkcp.vm_effective.current_plan_digest = EXCLUDED.current_plan_digest THEN bkcp.vm_effective.state ELSE 'pending' END,
    current_plan_digest = EXCLUDED.current_plan_digest,
    updated_at = CURRENT_TIMESTAMP`, resourceUUID, plan.PlanDigest); err != nil {
		return state.PreparedApply{}, fmt.Errorf("update effective state: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return state.PreparedApply{}, fmt.Errorf("commit prepared apply: %w", err)
	}
	return state.PreparedApply{
		Resource: state.ResourceSummary{UUID: resourceUUID, Name: normalized.Name, Managed: true, Generation: generation, EffectiveState: "pending", OperationStatus: operation.Status},
		Plan:     plan, Operation: operation, Created: created,
	}, nil
}

func (r *Repository) ListResources(ctx context.Context) ([]state.ResourceSummary, error) {
	rows, err := r.pool.Query(ctx, `
SELECT r.uuid::text, r.name, r.managed, COALESCE(r.current_generation, 0), COALESCE(e.state, 'pending'), COALESCE(o.status, '')
FROM bkcp.resources r
LEFT JOIN bkcp.vm_effective e ON e.resource_uuid = r.uuid
LEFT JOIN LATERAL (
    SELECT status FROM bkcp.operations WHERE resource_uuid = r.uuid ORDER BY created_at DESC, uuid DESC LIMIT 1
) o ON TRUE
WHERE r.archived_at IS NULL
ORDER BY r.name`)
	if err != nil {
		return nil, fmt.Errorf("list resources: %w", err)
	}
	defer rows.Close()
	var result []state.ResourceSummary
	for rows.Next() {
		var item state.ResourceSummary
		if err := rows.Scan(&item.UUID, &item.Name, &item.Managed, &item.Generation, &item.EffectiveState, &item.OperationStatus); err != nil {
			return nil, fmt.Errorf("scan resource: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list resources: %w", err)
	}
	return result, nil
}

func (r *Repository) InspectResource(ctx context.Context, name string) (state.Inspection, error) {
	var out state.Inspection
	if err := r.pool.QueryRow(ctx, `
SELECT r.uuid::text, r.name, r.managed, COALESCE(r.current_generation, 0), COALESCE(e.state, 'pending'), COALESCE(o.status, '')
FROM bkcp.resources r
LEFT JOIN bkcp.vm_effective e ON e.resource_uuid = r.uuid
LEFT JOIN LATERAL (SELECT status FROM bkcp.operations WHERE resource_uuid = r.uuid ORDER BY created_at DESC, uuid DESC LIMIT 1) o ON TRUE
WHERE r.name = $1 AND r.archived_at IS NULL`, name).Scan(&out.Resource.UUID, &out.Resource.Name, &out.Resource.Managed, &out.Resource.Generation, &out.Resource.EffectiveState, &out.Resource.OperationStatus); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return state.Inspection{}, state.ErrNotFound
		}
		return state.Inspection{}, fmt.Errorf("inspect resource: %w", err)
	}
	if out.Resource.Generation > 0 {
		var declared state.DeclaredVM
		var specJSON []byte
		if err := r.pool.QueryRow(ctx, `
SELECT resource_uuid::text, generation, normalized_spec, spec_digest, COALESCE(source_path, ''), declared_at
FROM bkcp.vm_specs WHERE resource_uuid = $1 AND generation = $2`, out.Resource.UUID, out.Resource.Generation).Scan(&declared.ResourceUUID, &declared.Generation, &specJSON, &declared.SpecDigest, &declared.SourcePath, &declared.DeclaredAt); err != nil {
			return state.Inspection{}, fmt.Errorf("inspect declaration: %w", err)
		}
		if err := json.Unmarshal(specJSON, &declared.Specification); err != nil {
			return state.Inspection{}, fmt.Errorf("decode declaration: %w", err)
		}
		out.Declared = &declared
	}
	var allocation state.Allocation
	var ipAddress, macAddress, datasetName, zvolName, imageDigest *string
	var keaSubnetID *int
	if err := r.pool.QueryRow(ctx, `
SELECT pool_name, ip_address::text, mac_address::text, dataset_name, zvol_name, kea_subnet_id, image_name, image_digest, allocation_generation, allocated_at, released_at
FROM bkcp.vm_allocations WHERE resource_uuid = $1`, out.Resource.UUID).Scan(
		&allocation.PoolName, &ipAddress, &macAddress, &datasetName, &zvolName, &keaSubnetID, &allocation.ImageName, &imageDigest, &allocation.AllocationGeneration, &allocation.AllocatedAt, &allocation.ReleasedAt,
	); err == nil {
		if ipAddress != nil {
			allocation.IPAddress = *ipAddress
		}
		if macAddress != nil {
			allocation.MACAddress = *macAddress
		}
		if datasetName != nil {
			allocation.DatasetName = *datasetName
		}
		if zvolName != nil {
			allocation.ZvolName = *zvolName
		}
		if keaSubnetID != nil {
			allocation.KeaSubnetID = *keaSubnetID
		}
		if imageDigest != nil {
			allocation.ImageDigest = *imageDigest
		}
		out.Allocation = &allocation
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return state.Inspection{}, fmt.Errorf("inspect allocation: %w", err)
	}
	var effective state.Effective
	if err := r.pool.QueryRow(ctx, `SELECT state, COALESCE(reason_code, ''), COALESCE(reason_detail, ''), COALESCE(current_plan_digest, ''), updated_at FROM bkcp.vm_effective WHERE resource_uuid = $1`, out.Resource.UUID).Scan(&effective.State, &effective.ReasonCode, &effective.ReasonDetail, &effective.CurrentPlanDigest, &effective.UpdatedAt); err == nil {
		out.Effective = &effective
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return state.Inspection{}, fmt.Errorf("inspect effective state: %w", err)
	}
	operation, err := r.latestOperation(ctx, out.Resource.UUID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return state.Inspection{}, err
	}
	if err == nil {
		out.Operation = &operation
		steps, err := r.operationSteps(ctx, operation.UUID)
		if err != nil {
			return state.Inspection{}, err
		}
		out.Steps = steps
		for i := range steps {
			if steps[i].Status != "succeeded" && steps[i].Status != "skipped" {
				step := steps[i]
				out.ResumeStep = &step
				break
			}
		}
	}
	return out, nil
}

func (r *Repository) latestOperation(ctx context.Context, resourceUUID string) (state.Operation, error) {
	var operation state.Operation
	err := r.pool.QueryRow(ctx, `
SELECT uuid::text, resource_uuid::text, generation, action, spec_digest, plan_digest, idempotency_key, status, attempts, created_at, started_at, completed_at, COALESCE(error_code, ''), COALESCE(error_detail, '')
FROM bkcp.operations WHERE resource_uuid = $1 ORDER BY created_at DESC, uuid DESC LIMIT 1`, resourceUUID).Scan(
		&operation.UUID, &operation.ResourceUUID, &operation.Generation, &operation.Action, &operation.SpecDigest, &operation.PlanDigest, &operation.IdempotencyKey,
		&operation.Status, &operation.Attempts, &operation.CreatedAt, &operation.StartedAt, &operation.CompletedAt, &operation.ErrorCode, &operation.ErrorDetail,
	)
	return operation, err
}

func (r *Repository) operationSteps(ctx context.Context, operationUUID string) ([]state.OperationStep, error) {
	rows, err := r.pool.Query(ctx, `
SELECT operation_uuid::text, sequence, driver, action, input_digest, status, attempts, started_at, completed_at, COALESCE(error_code, ''), COALESCE(error_detail, '')
FROM bkcp.operation_steps WHERE operation_uuid = $1 ORDER BY sequence`, operationUUID)
	if err != nil {
		return nil, fmt.Errorf("inspect operation steps: %w", err)
	}
	defer rows.Close()
	var result []state.OperationStep
	for rows.Next() {
		var step state.OperationStep
		if err := rows.Scan(&step.OperationUUID, &step.Sequence, &step.Driver, &step.Action, &step.InputDigest, &step.Status, &step.Attempts, &step.StartedAt, &step.CompletedAt, &step.ErrorCode, &step.ErrorDetail); err != nil {
			return nil, fmt.Errorf("scan operation step: %w", err)
		}
		result = append(result, step)
	}
	return result, rows.Err()
}

var _ state.Repository = (*Repository)(nil)
