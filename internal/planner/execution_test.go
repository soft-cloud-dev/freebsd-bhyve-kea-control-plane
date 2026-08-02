package planner

import (
	"strings"
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

func TestExecutableApplyBindsAllocation(t *testing.T) {
	site := config.Site{
		Schema: 1, ControlPlaneID: "lab-01",
		Host:    config.Host{VMBridge: "public", VMDataset: "zroot/vm", VMRoot: "/zroot/vm"},
		Kea:     config.Kea{APIURL: "http://127.0.0.1:8000/", UsernameFile: "/kea/user", PasswordFile: "/kea/pass"},
		Network: config.Network{PFAnchor: "bkcp", ManageAnchor: true},
		Pools:   []config.Pool{{Name: "vm-lan", Gateway: "10.0.20.1", DNSServers: []string{"10.0.20.1"}, VLAN: 20, KeaSubnetID: 1}},
		Images:  []config.Image{{Name: "freebsd", URL: "https://example/image.raw.xz", CompressedSHA256: strings.Repeat("a", 64), Format: "raw.xz", Loader: "bhyveload"}},
	}
	manifest := config.VMManifest{Schema: 1, Name: "node-01", Owner: "admin", Image: "freebsd", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}
	allocated := Allocation{PoolName: "vm-lan", IPAddress: "10.0.20.10", MACAddress: "02:00:00:00:00:01", DatasetName: "zroot/vm/node-01", ZvolName: "zroot/vm/node-01/disk0", KeaSubnetID: 1, ImageName: "freebsd", ImageDigest: strings.Repeat("a", 64), AllocationGeneration: 1}
	first, err := BuildExecutableApply(site, 1, manifest, allocated)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildExecutableApply(site, 1, manifest, allocated)
	if err != nil {
		t.Fatal(err)
	}
	if first.Plan.PlanDigest != second.Plan.PlanDigest || first.Plan.IdempotencyKey != second.Plan.IdempotencyKey {
		t.Fatal("identical executable inputs changed identity")
	}
	if len(first.Steps) != 9 || !strings.Contains(first.Steps[0].InputJSON, "10.0.20.10") {
		t.Fatalf("unexpected executable plan: %#v", first)
	}
	allocated.IPAddress = "10.0.20.11"
	changed, err := BuildExecutableApply(site, 1, manifest, allocated)
	if err != nil {
		t.Fatal(err)
	}
	if changed.Plan.PlanDigest == first.Plan.PlanDigest || changed.Plan.IdempotencyKey == first.Plan.IdempotencyKey {
		t.Fatal("changed allocation did not change executable identity")
	}
}

func TestDeleteRequiresDestructionAuthorization(t *testing.T) {
	_, err := BuildExecutableDelete(config.Site{}, 1, config.VMManifest{}, Allocation{}, false)
	if err == nil {
		t.Fatal("expected delete authorization error")
	}
}
