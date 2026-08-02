package planner

import (
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

func TestBuildApplyIsDeterministic(t *testing.T) {
	manifest := config.VMManifest{
		Schema: 1, Name: "freebsd-node-01", Owner: "admin", Image: "freebsd-14.3",
		Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running",
		CPUs: 2, MemoryMB: 4096, DiskGB: 32, SSHPublicKeyFile: "/root/.ssh/id_ed25519.pub",
	}
	first, err := BuildApply("lab-01", 1, manifest)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildApply("lab-01", 1, manifest)
	if err != nil {
		t.Fatal(err)
	}
	if first.PlanDigest != second.PlanDigest || first.IdempotencyKey != second.IdempotencyKey {
		t.Fatalf("plan is not deterministic: %#v != %#v", first, second)
	}
}

func TestBuildApplyChangesKeyWhenGenerationChanges(t *testing.T) {
	manifest := config.VMManifest{
		Schema: 1, Name: "freebsd-node-01", Owner: "admin", Image: "freebsd-14.3",
		Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running",
		CPUs: 2, MemoryMB: 4096, DiskGB: 32,
	}
	first, _ := BuildApply("lab-01", 1, manifest)
	second, _ := BuildApply("lab-01", 2, manifest)
	if first.IdempotencyKey == second.IdempotencyKey {
		t.Fatal("generation must alter idempotency key")
	}
}
