//go:build integration

package postgres

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/migrate"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

func TestPreparationBlockedByActiveExecution(t *testing.T) {
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
		Host: config.Host{VMBridge: "bridge0", VMSwitch: "public", VMDataset: "zroot/vm", VMRoot: "/zroot/vm"},
		Kea: config.Kea{APIURL: "http://127.0.0.1:8000/", UsernameFile: "/kea/user", PasswordFile: "/kea/pass"},
		Network: config.Network{PFAnchor: "bkcp", ManageAnchor: true},
		Pools: []config.Pool{{Name: "vm-lan", FirstHost: "10.0.20.10", LastHost: "10.0.20.20", Gateway: "10.0.20.1", DNSServers: []string{"10.0.20.1"}, VLAN: 20, KeaSubnetID: 1}},
		Images: []config.Image{{Name: "freebsd", URL: "https://example/image.raw.xz", CompressedSHA256: strings.Repeat("a", 64), Format: "raw.xz", Loader: "bhyveload"}},
	}
	manifest := config.VMManifest{Schema: 1, Name: "node-lock", Owner: "admin", Image: "freebsd", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}

	unlock, err := repo.LockExecution(ctx, manifest.Name)
	if err != nil {
		t.Fatal(err)
	}
	_, err = repo.PrepareExecutableApply(ctx, site, "node-lock.toml", manifest)
	if !errors.Is(err, state.ErrBlocked) {
		unlock()
		t.Fatalf("expected blocked preparation, got %v", err)
	}
	unlock()

	if _, err := repo.PrepareExecutableApply(ctx, site, "node-lock.toml", manifest); err != nil {
		t.Fatalf("preparation did not recover after lock release: %v", err)
	}
}
