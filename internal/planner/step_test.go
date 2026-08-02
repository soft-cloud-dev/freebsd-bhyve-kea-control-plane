package planner

import (
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

func TestBuildApplyStepDigestsAreStableAndDistinct(t *testing.T) {
	manifest := config.VMManifest{Schema: 1, Name: "node-01", Owner: "admin", Image: "freebsd-14.3", Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running", CPUs: 2, MemoryMB: 4096, DiskGB: 32}
	plan, err := BuildApply("lab-01", 1, manifest)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Steps) != 8 {
		t.Fatalf("steps=%d", len(plan.Steps))
	}
	seen := map[string]struct{}{}
	for _, step := range plan.Steps {
		if len(step.InputDigest) != 64 {
			t.Fatalf("step %d digest=%q", step.Sequence, step.InputDigest)
		}
		if _, exists := seen[step.InputDigest]; exists {
			t.Fatalf("duplicate step digest %s", step.InputDigest)
		}
		seen[step.InputDigest] = struct{}{}
	}
}
