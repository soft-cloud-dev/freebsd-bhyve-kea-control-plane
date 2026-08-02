package execution

import (
	"context"
	"fmt"
	"regexp"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

var serviceNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

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
	if input.Driver == "service" && input.Action == "ensure-ready" {
		return d.ensureServices(ctx, input)
	}
	if input.Driver == "vmbhyve" && input.Host.VMSwitch != "" {
		input.Host.VMBridge = input.Host.VMSwitch
	}
	return d.System.Ensure(ctx, input)
}

func (d *RuntimeDriver) ensureServices(ctx context.Context, input planner.StepInput) (Result, error) {
	if !input.Services.Manage {
		return Result{Skipped: true, Postcondition: map[string]any{"managed": false}}, nil
	}
	if len(input.Services.Names) == 0 {
		return Result{}, fmt.Errorf("%w: service management is enabled but no services are configured", state.ErrBlocked)
	}
	started := make([]string, 0, len(input.Services.Names))
	for _, name := range input.Services.Names {
		if !serviceNamePattern.MatchString(name) {
			return Result{}, fmt.Errorf("%w: invalid FreeBSD service name %q", state.ErrBlocked, name)
		}
		if _, err := d.System.Runner.Run(ctx, "service", name, "onestatus"); err != nil {
			if _, startErr := d.System.Runner.Run(ctx, "service", name, "start"); startErr != nil {
				return Result{}, fmt.Errorf("start service %s: %w", name, startErr)
			}
			started = append(started, name)
		}
		if _, err := d.System.Runner.Run(ctx, "service", name, "onestatus"); err != nil {
			return Result{}, fmt.Errorf("%w: service %s is not running after start: %v", state.ErrDrift, name, err)
		}
	}
	return Result{Postcondition: map[string]any{"services": input.Services.Names, "started": started, "ready": true}}, nil
}
