package postgres

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/allocation"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

func (r *Repository) PrepareExecutableApply(ctx context.Context, site config.Site, sourcePath string, manifest config.VMManifest) (state.PreparedApply, error) {
	if err := manifest.Validate(); err != nil {
		return state.PreparedApply{}, err
	}
	pool, image, err := siteReferences(site, manifest)
	if err != nil {
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
		return state.PreparedApply{}, fmt.Errorf("begin executable apply: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, resourceLockKey(site.ControlPlaneID, normalized.Name)); err != nil {
		return state.PreparedApply{}, fmt.Errorf("lock resource: %w", err)
	}
	resourceUUID, generation, declarationChanged, err := prepareDeclaration(ctx, tx, normalized, specDigest, specJSON, sourcePath)
	if err != nil {
		return state.PreparedApply{}, err
	}
	allocated, err := ensureAllocation(ctx, tx, site, pool, image, resourceUUID, normalized.Name, generation)
	if err != nil {
		return state.PreparedApply{}, err
	}
	executable, err := planner.BuildExecutableApply(site, generation, manifest, plannerAllocation(allocated))
	if err != nil {
		return state.PreparedApply{}, err
	}
	operation, created, err := persistExecutableOperation(ctx, tx, resourceUUID, executable)
	if err != nil {
		return state.PreparedApply{}, err
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_effective(resource_uuid, state, current_plan_digest)
VALUES ($1, 'pending', $2)
ON CONFLICT (resource_uuid) DO UPDATE
SET state = CASE WHEN bkcp.vm_effective.state = 'converged' AND bkcp.vm_effective.current_plan_digest = EXCLUDED.current_plan_digest THEN bkcp.vm_effective.state ELSE 'pending' END,
    reason_code = NULL, reason_detail = NULL,
    current_plan_digest = EXCLUDED.current_plan_digest,
    updated_at = CURRENT_TIMESTAMP`, resourceUUID, executable.Plan.PlanDigest); err != nil {
		return state.PreparedApply{}, fmt.Errorf("update effective state: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return state.PreparedApply{}, fmt.Errorf("commit executable apply: %w", err)
	}
	_ = declarationChanged
	return state.PreparedApply{
		Resource: state.ResourceSummary{UUID: resourceUUID, Name: normalized.Name, Managed: true, Generation: generation, EffectiveState: "pending", OperationStatus: operation.Status},
		Plan:     executable.Plan, Operation: operation, Created: created,
	}, nil
}

func (r *Repository) PrepareExecutableDelete(ctx context.Context, site config.Site, name string, destroyStorage bool) (state.PreparedApply, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return state.PreparedApply{}, fmt.Errorf("begin delete preparation: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, resourceLockKey(site.ControlPlaneID, name)); err != nil {
		return state.PreparedApply{}, fmt.Errorf("lock resource: %w", err)
	}
	var resourceUUID string
	var generation uint64
	var specBytes []byte
	if err := tx.QueryRow(ctx, `
SELECT r.uuid::text, r.current_generation, s.normalized_spec
FROM bkcp.resources r
JOIN bkcp.vm_specs s ON s.resource_uuid = r.uuid AND s.generation = r.current_generation
WHERE r.name = $1 AND r.archived_at IS NULL`, name).Scan(&resourceUUID, &generation, &specBytes); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return state.PreparedApply{}, state.ErrNotFound
		}
		return state.PreparedApply{}, fmt.Errorf("load delete declaration: %w", err)
	}
	var normalized config.NormalizedVM
	if err := json.Unmarshal(specBytes, &normalized); err != nil {
		return state.PreparedApply{}, fmt.Errorf("decode delete declaration: %w", err)
	}
	manifest := manifestFromNormalized(normalized)
	allocated, err := loadAllocationTx(ctx, tx, resourceUUID)
	if err != nil {
		return state.PreparedApply{}, err
	}
	executable, err := planner.BuildExecutableDelete(site, generation, manifest, plannerAllocation(allocated), destroyStorage)
	if err != nil {
		return state.PreparedApply{}, err
	}
	operation, created, err := persistExecutableOperation(ctx, tx, resourceUUID, executable)
	if err != nil {
		return state.PreparedApply{}, err
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_effective(resource_uuid, state, current_plan_digest)
VALUES ($1, 'deleting', $2)
ON CONFLICT (resource_uuid) DO UPDATE SET state = 'deleting', reason_code = NULL, reason_detail = NULL, current_plan_digest = EXCLUDED.current_plan_digest, updated_at = CURRENT_TIMESTAMP`, resourceUUID, executable.Plan.PlanDigest); err != nil {
		return state.PreparedApply{}, fmt.Errorf("mark deleting: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return state.PreparedApply{}, fmt.Errorf("commit delete preparation: %w", err)
	}
	return state.PreparedApply{Resource: state.ResourceSummary{UUID: resourceUUID, Name: name, Managed: true, Generation: generation, EffectiveState: "deleting", OperationStatus: operation.Status}, Plan: executable.Plan, Operation: operation, Created: created}, nil
}

func prepareDeclaration(ctx context.Context, tx pgx.Tx, normalized config.NormalizedVM, specDigest string, specJSON []byte, sourcePath string) (string, uint64, bool, error) {
	var resourceUUID string
	var currentGeneration *int64
	if err := tx.QueryRow(ctx, `
INSERT INTO bkcp.resources(name, kind, managed)
VALUES ($1, 'vm', TRUE)
ON CONFLICT (name) DO UPDATE SET managed = TRUE, archived_at = NULL, updated_at = CURRENT_TIMESTAMP
RETURNING uuid::text, current_generation`, normalized.Name).Scan(&resourceUUID, &currentGeneration); err != nil {
		return "", 0, false, fmt.Errorf("load resource: %w", err)
	}
	generation := uint64(1)
	changed := true
	if currentGeneration != nil {
		generation = uint64(*currentGeneration)
		var currentDigest string
		if err := tx.QueryRow(ctx, `SELECT spec_digest FROM bkcp.vm_specs WHERE resource_uuid = $1 AND generation = $2`, resourceUUID, *currentGeneration).Scan(&currentDigest); err != nil {
			return "", 0, false, fmt.Errorf("load current declaration: %w", err)
		}
		if currentDigest == specDigest {
			changed = false
		} else {
			generation++
		}
	}
	if changed {
		if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.vm_specs(resource_uuid, generation, normalized_spec, spec_digest, desired_presence, desired_power, source_path)
VALUES ($1, $2, $3, $4, 'present', $5, NULLIF($6, ''))`, resourceUUID, generation, specJSON, specDigest, normalized.DesiredPower, sourcePath); err != nil {
			return "", 0, false, fmt.Errorf("insert declaration: %w", err)
		}
		if _, err := tx.Exec(ctx, `UPDATE bkcp.resources SET current_generation = $2, updated_at = CURRENT_TIMESTAMP WHERE uuid = $1`, resourceUUID, generation); err != nil {
			return "", 0, false, fmt.Errorf("advance generation: %w", err)
		}
	}
	return resourceUUID, generation, changed, nil
}

func ensureAllocation(ctx context.Context, tx pgx.Tx, site config.Site, pool config.Pool, image config.Image, resourceUUID, resourceName string, generation uint64) (state.Allocation, error) {
	allocated, loadErr := loadAllocationTx(ctx, tx, resourceUUID)
	if loadErr == nil && allocated.ReleasedAt == nil {
		if allocated.PoolName != pool.Name || allocated.ImageName != image.Name {
			return state.Allocation{}, fmt.Errorf("%w: changing pool or image requires explicit replacement", state.ErrBlocked)
		}
		return allocated, nil
	}
	if loadErr != nil && !errors.Is(loadErr, pgx.ErrNoRows) {
		return state.Allocation{}, loadErr
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, "bkcp:pool:"+site.ControlPlaneID+":"+pool.Name); err != nil {
		return state.Allocation{}, fmt.Errorf("lock pool: %w", err)
	}
	addresses, err := allocation.Addresses(pool.FirstHost, pool.LastHost)
	if err != nil {
		return state.Allocation{}, err
	}
	ipAddress := ""
	for _, candidate := range addresses {
		var used bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM bkcp.vm_allocations WHERE ip_address = $1::inet AND released_at IS NULL AND resource_uuid <> $2)`, candidate.String(), resourceUUID).Scan(&used); err != nil {
			return state.Allocation{}, fmt.Errorf("check IP allocation: %w", err)
		}
		if !used {
			ipAddress = candidate.String()
			break
		}
	}
	if ipAddress == "" {
		return state.Allocation{}, allocation.ErrExhausted
	}
	macAddress := ""
	for counter := uint32(0); counter < 65536; counter++ {
		candidate := allocation.MAC(site.ControlPlaneID, resourceName, counter)
		var used bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM bkcp.vm_allocations WHERE mac_address = $1::macaddr AND released_at IS NULL AND resource_uuid <> $2)`, candidate, resourceUUID).Scan(&used); err != nil {
			return state.Allocation{}, fmt.Errorf("check MAC allocation: %w", err)
		}
		if !used {
			macAddress = candidate
			break
		}
	}
	if macAddress == "" {
		return state.Allocation{}, allocation.ErrExhausted
	}
	allocated = state.Allocation{PoolName: pool.Name, IPAddress: ipAddress, MACAddress: macAddress, DatasetName: allocation.Dataset(site.Host.VMDataset, resourceName), ZvolName: allocation.Zvol(site.Host.VMDataset, resourceName), KeaSubnetID: pool.KeaSubnetID, ImageName: image.Name, ImageDigest: image.CompressedSHA256, AllocationGeneration: generation}
	if loadErr == nil {
		_, err = tx.Exec(ctx, `
UPDATE bkcp.vm_allocations SET pool_name=$2, ip_address=$3::inet, mac_address=$4::macaddr, dataset_name=$5, zvol_name=$6, kea_subnet_id=$7, image_name=$8, image_digest=$9, allocation_generation=$10, allocated_at=CURRENT_TIMESTAMP, released_at=NULL
WHERE resource_uuid=$1`, resourceUUID, allocated.PoolName, allocated.IPAddress, allocated.MACAddress, allocated.DatasetName, allocated.ZvolName, allocated.KeaSubnetID, allocated.ImageName, allocated.ImageDigest, allocated.AllocationGeneration)
	} else {
		_, err = tx.Exec(ctx, `
INSERT INTO bkcp.vm_allocations(resource_uuid, pool_name, ip_address, mac_address, dataset_name, zvol_name, kea_subnet_id, image_name, image_digest, allocation_generation)
VALUES ($1,$2,$3::inet,$4::macaddr,$5,$6,$7,$8,$9,$10)`, resourceUUID, allocated.PoolName, allocated.IPAddress, allocated.MACAddress, allocated.DatasetName, allocated.ZvolName, allocated.KeaSubnetID, allocated.ImageName, allocated.ImageDigest, allocated.AllocationGeneration)
	}
	if err != nil {
		return state.Allocation{}, fmt.Errorf("persist allocation: %w", err)
	}
	allocated.AllocatedAt = time.Now().UTC()
	return allocated, nil
}

func persistExecutableOperation(ctx context.Context, tx pgx.Tx, resourceUUID string, executable planner.ExecutablePlan) (state.Operation, bool, error) {
	plan := executable.Plan
	var operation state.Operation
	var created bool
	if err := tx.QueryRow(ctx, `
WITH inserted AS (
 INSERT INTO bkcp.operations(resource_uuid,generation,action,spec_digest,plan_digest,idempotency_key)
 VALUES ($1,$2,$3,$4,$5,$6)
 ON CONFLICT (idempotency_key) DO NOTHING
 RETURNING uuid::text,resource_uuid::text,generation,action,spec_digest,plan_digest,idempotency_key,status,attempts,created_at,started_at,completed_at,COALESCE(error_code,''),COALESCE(error_detail,''),TRUE
)
SELECT * FROM inserted
UNION ALL
SELECT uuid::text,resource_uuid::text,generation,action,spec_digest,plan_digest,idempotency_key,status,attempts,created_at,started_at,completed_at,COALESCE(error_code,''),COALESCE(error_detail,''),FALSE FROM bkcp.operations WHERE idempotency_key=$6
LIMIT 1`, resourceUUID, plan.Generation, plan.Action, plan.SpecDigest, plan.PlanDigest, plan.IdempotencyKey).Scan(
		&operation.UUID, &operation.ResourceUUID, &operation.Generation, &operation.Action, &operation.SpecDigest, &operation.PlanDigest, &operation.IdempotencyKey, &operation.Status, &operation.Attempts, &operation.CreatedAt, &operation.StartedAt, &operation.CompletedAt, &operation.ErrorCode, &operation.ErrorDetail, &created); err != nil {
		return state.Operation{}, false, fmt.Errorf("persist executable operation: %w", err)
	}
	for _, executableStep := range executable.Steps {
		step := executableStep.Step
		if _, err := tx.Exec(ctx, `
INSERT INTO bkcp.operation_steps(operation_uuid,sequence,driver,action,input_digest,input_json)
VALUES ($1,$2,$3,$4,$5,$6)
ON CONFLICT (operation_uuid,sequence) DO UPDATE
SET input_json=EXCLUDED.input_json
WHERE bkcp.operation_steps.input_digest=EXCLUDED.input_digest`, operation.UUID, step.Sequence, step.Driver, step.Action, step.InputDigest, executableStep.InputJSON); err != nil {
			return state.Operation{}, false, fmt.Errorf("persist executable step %d: %w", step.Sequence, err)
		}
	}
	return operation, created, nil
}

func (r *Repository) StartOperation(ctx context.Context, operationUUID string) error {
	command, err := r.pool.Exec(ctx, `UPDATE bkcp.operations SET status='running', attempts=attempts+1, started_at=COALESCE(started_at,CURRENT_TIMESTAMP), completed_at=NULL, error_code=NULL, error_detail=NULL, updated_at=CURRENT_TIMESTAMP WHERE uuid=$1 AND status IN ('pending','failed','blocked','running')`, operationUUID)
	if err != nil {
		return fmt.Errorf("start operation: %w", err)
	}
	if command.RowsAffected() == 0 {
		var status string
		if err := r.pool.QueryRow(ctx, `SELECT status FROM bkcp.operations WHERE uuid=$1`, operationUUID).Scan(&status); err != nil {
			return fmt.Errorf("load operation status: %w", err)
		}
		if status != "succeeded" {
			return fmt.Errorf("%w: operation status is %s", state.ErrBlocked, status)
		}
	}
	return nil
}

func (r *Repository) ClaimStep(ctx context.Context, operationUUID string, sequence int) (state.OperationStep, error) {
	var step state.OperationStep
	err := r.pool.QueryRow(ctx, `
UPDATE bkcp.operation_steps SET status='running', attempts=attempts+1, started_at=CURRENT_TIMESTAMP, completed_at=NULL, error_code=NULL, error_detail=NULL
WHERE operation_uuid=$1 AND sequence=$2 AND status IN ('pending','failed','running')
RETURNING operation_uuid::text,sequence,driver,action,input_digest,input_json,COALESCE(postcondition_json,''),COALESCE(postcondition_digest,''),status,attempts,started_at,completed_at,COALESCE(error_code,''),COALESCE(error_detail,'')`, operationUUID, sequence).Scan(&step.OperationUUID, &step.Sequence, &step.Driver, &step.Action, &step.InputDigest, &step.InputJSON, &step.PostconditionJSON, &step.PostconditionDigest, &step.Status, &step.Attempts, &step.StartedAt, &step.CompletedAt, &step.ErrorCode, &step.ErrorDetail)
	if err != nil {
		return state.OperationStep{}, fmt.Errorf("claim operation step: %w", err)
	}
	return step, nil
}

func (r *Repository) CompleteStep(ctx context.Context, operationUUID string, sequence int, postcondition any, skipped bool) error {
	encoded, err := json.Marshal(postcondition)
	if err != nil {
		return fmt.Errorf("encode postcondition: %w", err)
	}
	digest := sha256.Sum256(encoded)
	status := "succeeded"
	if skipped {
		status = "skipped"
	}
	_, err = r.pool.Exec(ctx, `UPDATE bkcp.operation_steps SET status=$3,postcondition_json=$4,postcondition_digest=$5,completed_at=CURRENT_TIMESTAMP,error_code=NULL,error_detail=NULL WHERE operation_uuid=$1 AND sequence=$2`, operationUUID, sequence, status, string(encoded), hex.EncodeToString(digest[:]))
	if err != nil {
		return fmt.Errorf("complete operation step: %w", err)
	}
	return nil
}

func (r *Repository) FailStep(ctx context.Context, operationUUID string, sequence int, code, detail string, blocked bool) error {
	operationStatus := "failed"
	if blocked {
		operationStatus = "blocked"
	}
	if len(detail) > 4096 {
		detail = detail[:4096]
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `UPDATE bkcp.operation_steps SET status='failed',completed_at=CURRENT_TIMESTAMP,error_code=$3,error_detail=$4 WHERE operation_uuid=$1 AND sequence=$2`, operationUUID, sequence, code, detail); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bkcp.operations SET status=$2,completed_at=CURRENT_TIMESTAMP,error_code=$3,error_detail=$4,updated_at=CURRENT_TIMESTAMP WHERE uuid=$1`, operationUUID, operationStatus, code, detail); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (r *Repository) CompleteOperation(ctx context.Context, operationUUID, resourceUUID, effectiveState string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `UPDATE bkcp.operations SET status='succeeded',completed_at=CURRENT_TIMESTAMP,error_code=NULL,error_detail=NULL,updated_at=CURRENT_TIMESTAMP WHERE uuid=$1`, operationUUID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE bkcp.vm_effective SET state=$2,reason_code=NULL,reason_detail=NULL,last_successful_reconciliation_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE resource_uuid=$1`, resourceUUID, effectiveState); err != nil {
		return err
	}
	if effectiveState == "absent" {
		if _, err := tx.Exec(ctx, `UPDATE bkcp.vm_allocations SET released_at=COALESCE(released_at,CURRENT_TIMESTAMP) WHERE resource_uuid=$1`, resourceUUID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE bkcp.resources SET archived_at=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE uuid=$1`, resourceUUID); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func (r *Repository) RecordObservation(ctx context.Context, observation state.Observation) error {
	observed, err := json.Marshal(observation.Observed)
	if err != nil {
		return err
	}
	if len(observation.ErrorDetail) > 4096 {
		observation.ErrorDetail = observation.ErrorDetail[:4096]
	}
	var uuid string
	return r.pool.QueryRow(ctx, `
INSERT INTO bkcp.vm_observations(resource_uuid,observer_version,vm_state,storage_state,kea_state,seed_state,power_state,observed,error_code,error_detail,plan_digest)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NULLIF($11,'')) RETURNING uuid::text`, observation.ResourceUUID, observation.ObserverVersion, observation.VMState, observation.StorageState, observation.KeaState, observation.SeedState, observation.PowerState, observed, nullString(observation.ErrorCode), nullString(observation.ErrorDetail), observation.PlanDigest).Scan(&uuid)
}

func loadAllocationTx(ctx context.Context, tx pgx.Tx, resourceUUID string) (state.Allocation, error) {
	var out state.Allocation
	var ip, mac, dataset, zvol, digest *string
	var kea *int
	err := tx.QueryRow(ctx, `SELECT pool_name,ip_address::text,mac_address::text,dataset_name,zvol_name,kea_subnet_id,image_name,image_digest,allocation_generation,allocated_at,released_at FROM bkcp.vm_allocations WHERE resource_uuid=$1`, resourceUUID).Scan(&out.PoolName, &ip, &mac, &dataset, &zvol, &kea, &out.ImageName, &digest, &out.AllocationGeneration, &out.AllocatedAt, &out.ReleasedAt)
	if err != nil {
		return state.Allocation{}, err
	}
	if ip != nil {
		out.IPAddress = *ip
	}
	if mac != nil {
		out.MACAddress = *mac
	}
	if dataset != nil {
		out.DatasetName = *dataset
	}
	if zvol != nil {
		out.ZvolName = *zvol
	}
	if kea != nil {
		out.KeaSubnetID = *kea
	}
	if digest != nil {
		out.ImageDigest = *digest
	}
	return out, nil
}

func plannerAllocation(input state.Allocation) planner.Allocation {
	return planner.Allocation{PoolName: input.PoolName, IPAddress: input.IPAddress, MACAddress: input.MACAddress, DatasetName: input.DatasetName, ZvolName: input.ZvolName, KeaSubnetID: input.KeaSubnetID, ImageName: input.ImageName, ImageDigest: input.ImageDigest, AllocationGeneration: input.AllocationGeneration}
}

func manifestFromNormalized(input config.NormalizedVM) config.VMManifest {
	return config.VMManifest{Schema: input.Schema, Name: input.Name, Owner: input.Owner, Image: input.Image, Profile: input.Profile, Pool: input.Pool, DesiredPower: input.DesiredPower, CPUs: input.CPUs, MemoryMB: input.MemoryMB, DiskGB: input.DiskGB, SSHPublicKeyFile: input.SSHPublicKeyFile}
}

func siteReferences(site config.Site, manifest config.VMManifest) (config.Pool, config.Image, error) {
	var pool config.Pool
	found := false
	for _, candidate := range site.Pools {
		if candidate.Name == manifest.Pool {
			pool = candidate
			found = true
			break
		}
	}
	if !found {
		return config.Pool{}, config.Image{}, fmt.Errorf("manifest references unknown pool %q", manifest.Pool)
	}
	var image config.Image
	found = false
	for _, candidate := range site.Images {
		if candidate.Name == manifest.Image {
			image = candidate
			found = true
			break
		}
	}
	if !found {
		return config.Pool{}, config.Image{}, fmt.Errorf("manifest references unknown image %q", manifest.Image)
	}
	return pool, image, nil
}

func nullString(value string) any {
	if value == "" {
		return nil
	}
	return value
}
