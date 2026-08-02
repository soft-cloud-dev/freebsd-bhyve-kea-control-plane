package execution

import (
	"context"
	"strings"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
)

type RuntimeDriver struct {
	System *SystemDriver
}

func NewRuntimeDriver() *RuntimeDriver {
	return &RuntimeDriver{System: NewSystemDriver()}
}

func (d *RuntimeDriver) Ensure(ctx context.Context, input planner.StepInput) (Result, error) {
	if d.System == nil {
		d.System = NewSystemDriver()
	}
	if input.Driver == "vmbhyve" || strings.HasPrefix(input.Action, "ensure-definition") || strings.HasPrefix(input.Action, "ensure-config") {
		if input.Host.VMSwitch != "" {
			input.Host.VMBridge = input.Host.VMSwitch
		}
	}
	return d.System.Ensure(ctx, input)
}
