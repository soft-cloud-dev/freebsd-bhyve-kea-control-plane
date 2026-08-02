//go:build integration

package postgres

import (
	"context"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/migrate"
)

func TestPrepareApplyConcurrent(t *testing.T) {
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
	repo, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer repo.Close()
	manifest := config.VMManifest{Schema: 1, Name: "node-01", Owner: "admin", Image: "freebsd-14.3", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}
	const callers = 32
	results := make(chan string, callers)
	errs := make(chan error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			prepared, err := repo.PrepareApply(ctx, "lab-01", "node-01.toml", manifest)
			if err != nil {
				errs <- err
				return
			}
			results <- prepared.Operation.IdempotencyKey
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	var key string
	for result := range results {
		if key == "" {
			key = result
		}
		if result != key {
			t.Fatalf("different idempotency keys: %s != %s", result, key)
		}
	}
	var resources, specs, operations, steps int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM bkcp.resources`).Scan(&resources); err != nil {
		t.Fatal(err)
	}
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM bkcp.vm_specs`).Scan(&specs); err != nil {
		t.Fatal(err)
	}
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM bkcp.operations`).Scan(&operations); err != nil {
		t.Fatal(err)
	}
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM bkcp.operation_steps`).Scan(&steps); err != nil {
		t.Fatal(err)
	}
	if resources != 1 || specs != 1 || operations != 1 || steps != 8 {
		t.Fatalf("counts resources=%d specs=%d operations=%d steps=%d", resources, specs, operations, steps)
	}
}

func TestMigrationAndGenerationSemantics(t *testing.T) {
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
	firstMigration, err := runner.Run(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}
	if len(firstMigration.Applied) != 1 {
		t.Fatalf("applied=%d", len(firstMigration.Applied))
	}
	secondMigration, err := runner.Run(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}
	if len(secondMigration.Applied) != 0 {
		t.Fatalf("second run applied=%d", len(secondMigration.Applied))
	}
	repo, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer repo.Close()
	manifest := config.VMManifest{Schema: 1, Name: "node-02", Owner: "admin", Image: "freebsd-14.3", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}
	first, err := repo.PrepareApply(ctx, "lab-01", "node-02.toml", manifest)
	if err != nil {
		t.Fatal(err)
	}
	second, err := repo.PrepareApply(ctx, "lab-01", "node-02.toml", manifest)
	if err != nil {
		t.Fatal(err)
	}
	if first.Resource.Generation != 1 || second.Resource.Generation != 1 || first.Operation.IdempotencyKey != second.Operation.IdempotencyKey {
		t.Fatalf("identical declaration changed identity: %#v %#v", first, second)
	}
	manifest.MemoryMB = 8192
	changed, err := repo.PrepareApply(ctx, "lab-01", "node-02.toml", manifest)
	if err != nil {
		t.Fatal(err)
	}
	if changed.Resource.Generation != 2 || changed.Operation.IdempotencyKey == first.Operation.IdempotencyKey {
		t.Fatalf("changed declaration not advanced: %#v", changed)
	}
	inspection, err := repo.InspectResource(ctx, "node-02")
	if err != nil {
		t.Fatal(err)
	}
	if inspection.ResumeStep == nil || inspection.ResumeStep.Sequence != 1 || len(inspection.Steps) != 8 {
		t.Fatalf("invalid resume state: %#v", inspection)
	}
}
