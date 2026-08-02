package planner

import (
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

func BuildExecutableReconcile(site config.Site, generation uint64, manifest config.VMManifest, allocation Allocation) (ExecutablePlan, error) {
	return buildExecutable(site, generation, manifest, allocation, "reconcile", false, [][2]string{{"observer", "observe-all"}})
}
