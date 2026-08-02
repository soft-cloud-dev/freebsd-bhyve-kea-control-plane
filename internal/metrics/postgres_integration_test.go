//go:build integration

package metrics

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/migrate"
)

func TestPostgresSnapshot(t *testing.T) {
	dsn := os.Getenv("BKCP_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("BKCP_TEST_DATABASE_URL is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, `DROP SCHEMA IF EXISTS bkcp CASCADE`); err != nil {
		t.Fatal(err)
	}
	runner, err := migrate.New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Run(ctx, conn); err != nil {
		t.Fatal(err)
	}

	var resourceUUID string
	if err := conn.QueryRow(ctx, `
INSERT INTO bkcp.resources(name, kind, managed)
VALUES ('node-01', 'vm', TRUE)
RETURNING uuid::text`).Scan(&resourceUUID); err != nil {
		t.Fatal(err)
	}
	digest := strings.Repeat("a", 64)
	planDigest := strings.Repeat("b", 64)
	idempotencyKey := strings.Repeat("c", 64)

	statements := []struct {
		query string
		args  []any
	}{
		{
			query: `
INSERT INTO bkcp.vm_specs(resource_uuid, generation, normalized_spec, spec_digest, desired_presence, desired_power)
VALUES ($1, 1, '{"name":"node-01","image":"freebsd-14.4","pool":"vm-lan","desired_power":"running"}', $2, 'present', 'running')`,
			args: []any{resourceUUID, digest},
		},
		{
			query: `UPDATE bkcp.resources SET current_generation = 1 WHERE uuid = $1`,
			args:  []any{resourceUUID},
		},
		{
			query: `
INSERT INTO bkcp.vm_allocations(resource_uuid, pool_name, ip_address, mac_address, dataset_name, zvol_name, kea_subnet_id, image_name, image_digest, allocation_generation)
VALUES ($1, 'vm-lan', '10.0.20.10', '02:00:00:00:00:01', 'zroot/vm/node-01', 'zroot/vm/node-01/disk0', 1, 'freebsd-14.4', $2, 1)`,
			args: []any{resourceUUID, digest},
		},
		{
			query: `
INSERT INTO bkcp.vm_effective(resource_uuid, state, current_plan_digest, last_successful_reconciliation_at)
VALUES ($1, 'converged', $2, CURRENT_TIMESTAMP)`,
			args: []any{resourceUUID, planDigest},
		},
		{
			query: `
INSERT INTO bkcp.vm_observations(resource_uuid, observer_version, vm_state, storage_state, kea_state, seed_state, image_state, pf_state, power_state, observed, plan_digest)
VALUES ($1, 'test', 'present', 'present', 'present', 'present', 'present', 'present', 'running', '{}', $2)`,
			args: []any{resourceUUID, planDigest},
		},
	}
	for _, statement := range statements {
		if _, err := conn.Exec(ctx, statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}

	var operationUUID string
	if err := conn.QueryRow(ctx, `
INSERT INTO bkcp.operations(resource_uuid, generation, action, spec_digest, plan_digest, idempotency_key, status, attempts, completed_at)
VALUES ($1, 1, 'apply', $2, $3, $4, 'succeeded', 1, CURRENT_TIMESTAMP)
RETURNING uuid::text`, resourceUUID, digest, planDigest, idempotencyKey).Scan(&operationUUID); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `
INSERT INTO bkcp.operation_steps(operation_uuid, sequence, driver, action, input_digest, status, attempts)
VALUES ($1, 1, 'zfs', 'ensure-storage', $2, 'succeeded', 1)`, operationUUID, digest); err != nil {
		t.Fatal(err)
	}

	source, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	if _, err := source.pool.Exec(ctx, `CREATE TEMP TABLE exporter_must_be_read_only(id integer)`); err == nil {
		t.Fatal("metrics PostgreSQL session accepted a write")
	}
	snapshot, err := source.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Resources) != 1 {
		t.Fatalf("resources = %d", len(snapshot.Resources))
	}
	resource := snapshot.Resources[0]
	if resource.Name != "node-01" || resource.Generation != 1 || resource.EffectiveState != "converged" {
		t.Fatalf("resource = %#v", resource)
	}
	if resource.ObservationStates["power"] != "running" || resource.LatestOperationStatus != "succeeded" {
		t.Fatalf("observation or operation missing: %#v", resource)
	}
	if len(snapshot.OperationCounts) != 1 || snapshot.OperationCounts[0].Count != 1 {
		t.Fatalf("operation counts = %#v", snapshot.OperationCounts)
	}
	if len(snapshot.StepCounts) != 1 || snapshot.StepCounts[0].Driver != "zfs" {
		t.Fatalf("step counts = %#v", snapshot.StepCounts)
	}
	if len(snapshot.AllocationCounts) != 1 || snapshot.AllocationCounts[0].State != "active" {
		t.Fatalf("allocation counts = %#v", snapshot.AllocationCounts)
	}
}
