package metrics

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type PostgresSource struct {
	pool *pgxpool.Pool
}

func OpenPostgres(ctx context.Context, dsn string) (*PostgresSource, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("configure metrics PostgreSQL pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect metrics PostgreSQL pool: %w", err)
	}
	return &PostgresSource{pool: pool}, nil
}

func (s *PostgresSource) Close() {
	if s != nil && s.pool != nil {
		s.pool.Close()
	}
}

func (s *PostgresSource) Ping(ctx context.Context) error {
	if s == nil || s.pool == nil {
		return fmt.Errorf("metrics PostgreSQL source is not initialized")
	}
	return s.pool.Ping(ctx)
}

func (s *PostgresSource) Snapshot(ctx context.Context) (Snapshot, error) {
	if s == nil || s.pool == nil {
		return Snapshot{}, fmt.Errorf("metrics PostgreSQL source is not initialized")
	}

	snapshot := Snapshot{CollectedAt: time.Now().UTC()}
	if err := s.collectResources(ctx, &snapshot); err != nil {
		return Snapshot{}, err
	}
	if err := s.collectOperationCounts(ctx, &snapshot); err != nil {
		return Snapshot{}, err
	}
	if err := s.collectStepCounts(ctx, &snapshot); err != nil {
		return Snapshot{}, err
	}
	if err := s.collectAllocationCounts(ctx, &snapshot); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

func (s *PostgresSource) collectResources(ctx context.Context, snapshot *Snapshot) error {
	rows, err := s.pool.Query(ctx, `
SELECT r.name,
       r.managed,
       COALESCE(r.current_generation, 0),
       COALESCE(e.state, 'pending'),
       COALESCE(spec.desired_power, ''),
       COALESCE(a.pool_name, ''),
       COALESCE(a.image_name, ''),
       e.last_successful_reconciliation_at,
       observation.collected_at,
       COALESCE(observation.vm_state, 'unknown'),
       COALESCE(observation.storage_state, 'unknown'),
       COALESCE(observation.kea_state, 'unknown'),
       COALESCE(observation.seed_state, 'unknown'),
       COALESCE(observation.image_state, 'unknown'),
       COALESCE(observation.pf_state, 'unknown'),
       COALESCE(observation.power_state, 'unknown'),
       COALESCE(operation.action, ''),
       COALESCE(operation.status, ''),
       COALESCE(operation.attempts, 0)
FROM bkcp.resources r
LEFT JOIN bkcp.vm_specs spec
       ON spec.resource_uuid = r.uuid
      AND spec.generation = r.current_generation
LEFT JOIN bkcp.vm_allocations a
       ON a.resource_uuid = r.uuid
LEFT JOIN bkcp.vm_effective e
       ON e.resource_uuid = r.uuid
LEFT JOIN LATERAL (
    SELECT collected_at, vm_state, storage_state, kea_state, seed_state,
           image_state, pf_state, power_state
    FROM bkcp.vm_observations
    WHERE resource_uuid = r.uuid
    ORDER BY collected_at DESC, uuid DESC
    LIMIT 1
) observation ON TRUE
LEFT JOIN LATERAL (
    SELECT action, status, attempts
    FROM bkcp.operations
    WHERE resource_uuid = r.uuid
    ORDER BY created_at DESC, uuid DESC
    LIMIT 1
) operation ON TRUE
WHERE r.archived_at IS NULL
ORDER BY r.name`)
	if err != nil {
		return fmt.Errorf("query resource metrics: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var resource Resource
		var generation int64
		var reconciliationAt *time.Time
		var observationAt *time.Time
		var vmState, storageState, keaState, seedState string
		var imageState, pfState, powerState string
		if err := rows.Scan(
			&resource.Name,
			&resource.Managed,
			&generation,
			&resource.EffectiveState,
			&resource.DesiredPower,
			&resource.Pool,
			&resource.Image,
			&reconciliationAt,
			&observationAt,
			&vmState,
			&storageState,
			&keaState,
			&seedState,
			&imageState,
			&pfState,
			&powerState,
			&resource.LatestOperationAction,
			&resource.LatestOperationStatus,
			&resource.LatestOperationAttempts,
		); err != nil {
			return fmt.Errorf("scan resource metrics: %w", err)
		}
		if generation > 0 {
			resource.Generation = uint64(generation)
		}
		resource.LastSuccessfulReconciliationAt = reconciliationAt
		resource.ObservationCollectedAt = observationAt
		resource.ObservationStates = map[string]string{
			"vm":      vmState,
			"storage": storageState,
			"kea":     keaState,
			"seed":    seedState,
			"image":   imageState,
			"pf":      pfState,
			"power":   powerState,
		}
		snapshot.Resources = append(snapshot.Resources, resource)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate resource metrics: %w", err)
	}
	return nil
}

func (s *PostgresSource) collectOperationCounts(ctx context.Context, snapshot *Snapshot) error {
	rows, err := s.pool.Query(ctx, `
SELECT action, status, count(*)
FROM bkcp.operations
GROUP BY action, status
ORDER BY action, status`)
	if err != nil {
		return fmt.Errorf("query operation metrics: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var item OperationCount
		if err := rows.Scan(&item.Action, &item.Status, &item.Count); err != nil {
			return fmt.Errorf("scan operation metrics: %w", err)
		}
		snapshot.OperationCounts = append(snapshot.OperationCounts, item)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate operation metrics: %w", err)
	}
	return nil
}

func (s *PostgresSource) collectStepCounts(ctx context.Context, snapshot *Snapshot) error {
	rows, err := s.pool.Query(ctx, `
SELECT driver, action, status, count(*)
FROM bkcp.operation_steps
GROUP BY driver, action, status
ORDER BY driver, action, status`)
	if err != nil {
		return fmt.Errorf("query operation-step metrics: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var item StepCount
		if err := rows.Scan(&item.Driver, &item.Action, &item.Status, &item.Count); err != nil {
			return fmt.Errorf("scan operation-step metrics: %w", err)
		}
		snapshot.StepCounts = append(snapshot.StepCounts, item)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate operation-step metrics: %w", err)
	}
	return nil
}

func (s *PostgresSource) collectAllocationCounts(ctx context.Context, snapshot *Snapshot) error {
	rows, err := s.pool.Query(ctx, `
SELECT pool_name,
       CASE WHEN released_at IS NULL THEN 'active' ELSE 'released' END,
       count(*)
FROM bkcp.vm_allocations
GROUP BY pool_name, CASE WHEN released_at IS NULL THEN 'active' ELSE 'released' END
ORDER BY pool_name, CASE WHEN released_at IS NULL THEN 'active' ELSE 'released' END`)
	if err != nil {
		return fmt.Errorf("query allocation metrics: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var item AllocationCount
		if err := rows.Scan(&item.Pool, &item.State, &item.Count); err != nil {
			return fmt.Errorf("scan allocation metrics: %w", err)
		}
		snapshot.AllocationCounts = append(snapshot.AllocationCounts, item)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate allocation metrics: %w", err)
	}
	return nil
}
