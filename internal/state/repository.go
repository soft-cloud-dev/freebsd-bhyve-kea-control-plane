package state

import (
	"context"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

type Repository interface {
	PrepareApply(context.Context, string, string, config.VMManifest) (PreparedApply, error)
	ListResources(context.Context) ([]ResourceSummary, error)
	InspectResource(context.Context, string) (Inspection, error)
}
