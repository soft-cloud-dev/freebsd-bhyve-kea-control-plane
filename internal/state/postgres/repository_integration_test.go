//go:build integration

package postgres

import (
	"context"
	"os"
	"strings"
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
	if len(firstMigration.Applied) != 2 {
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

func TestExecutableAllocationAndInputs(t *testing.T) {
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
	site := config.Site{
		Schema: 1, ControlPlaneID: "lab-01",
		Host:    config.Host{VMBridge: "public", VMDataset: "zroot/vm", VMRoot: "/zroot/vm"},
		Kea:     config.Kea{APIURL: "http://127.0.0.1:8000/", UsernameFile: "/kea/user", PasswordFile: "/kea/pass"},
		Network: config.Network{PFAnchor: "bkcp", ManageAnchor: true},
		Pools:   []config.Pool{{Name: "vm-lan", FirstHost: "10.0.20.10", LastHost: "10.0.20.11", Gateway: "10.0.20.1", DNSServers: []string{"10.0.20.1"}, VLAN: 20, KeaSubnetID: 1}},
		Images:  []config.Image{{Name: "freebsd", URL: "https://example/image.raw.xz", CompressedSHA256: strings.Repeat("a", 64), Format: "raw.xz", Loader: "bhyveload"}},
	}
	firstManifest := config.VMManifest{Schema: 1, Name: "node-a", Owner: "admin", Image: "freebsd", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}
	first, err := repo.PrepareExecutableApply(ctx, site, "node-a.toml", firstManifest)
	if err != nil {
		t.Fatal(err)
	}
	repeated, err := repo.PrepareExecutableApply(ctx, site, "node-a.toml", firstManifest)
	if err != nil {
		t.Fatal(err)
	}
	if first.Operation.IdempotencyKey != repeated.Operation.IdempotencyKey {
		t.Fatal("repeated executable apply changed identity")
	}
	inspection, err := repo.InspectResource(ctx, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	if inspection.Allocation == nil || inspection.Allocation.IPAddress != "10.0.20.10" || inspection.Allocation.MACAddress == "" {
		t.Fatalf("unexpected allocation: %#v", inspection.Allocation)
	}
	steps, err := repo.ExecutionSteps(ctx, first.Operation.UUID)
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 9 || !strings.Contains(steps[0].InputJSON, "10.0.20.10") {
		t.Fatalf("unexpected steps: %#v", steps)
	}
	secondManifest := firstManifest
	secondManifest.Name = "node-b"
	if _, err := repo.PrepareExecutableApply(ctx, site, "node-b.toml", secondManifest); err != nil {
		t.Fatal(err)
	}
	secondInspection, err := repo.InspectResource(ctx, "node-b")
	if err != nil {
		t.Fatal(err)
	}
	if secondInspection.Allocation == nil || secondInspection.Allocation.IPAddress != "10.0.20.11" || secondInspection.Allocation.MACAddress == inspection.Allocation.MACAddress {
		t.Fatalf("allocation collision: first=%#v second=%#v", inspection.Allocation, secondInspection.Allocation)
	}
}
