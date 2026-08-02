package execution

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
)

type scriptedRunner struct {
	calls    [][]string
	statuses map[string]bool
}

func (r *scriptedRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	call := append([]string{name}, args...)
	r.calls = append(r.calls, call)
	if name != "service" || len(args) != 2 {
		return nil, errors.New("unexpected command")
	}
	service := args[0]
	switch args[1] {
	case "onestatus":
		if r.statuses[service] {
			return []byte("running"), nil
		}
		return nil, errors.New("not running")
	case "start":
		r.statuses[service] = true
		return []byte("started"), nil
	default:
		return nil, errors.New("unexpected service action")
	}
}

func TestRuntimeDriverEnsuresConfiguredServices(t *testing.T) {
	runner := &scriptedRunner{statuses: map[string]bool{"pf": true, "kea_dhcp4": false}}
	driver := &RuntimeDriver{System: &SystemDriver{Runner: runner}}
	input := planner.StepInput{
		Driver: "service", Action: "ensure-ready",
		Services: planner.ExecutionServices{Manage: true, Names: []string{"pf", "kea_dhcp4"}},
	}
	result, err := driver.Ensure(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if result.Skipped {
		t.Fatal("managed service step was skipped")
	}
	want := [][]string{
		{"service", "pf", "onestatus"},
		{"service", "pf", "onestatus"},
		{"service", "kea_dhcp4", "onestatus"},
		{"service", "kea_dhcp4", "start"},
		{"service", "kea_dhcp4", "onestatus"},
	}
	if !reflect.DeepEqual(runner.calls, want) {
		t.Fatalf("calls=%#v want=%#v", runner.calls, want)
	}
}

func TestRuntimeDriverRejectsInvalidServiceName(t *testing.T) {
	driver := &RuntimeDriver{System: &SystemDriver{Runner: &scriptedRunner{statuses: map[string]bool{}}}}
	_, err := driver.Ensure(context.Background(), planner.StepInput{
		Driver: "service", Action: "ensure-ready",
		Services: planner.ExecutionServices{Manage: true, Names: []string{"pf;rm"}},
	})
	if err == nil {
		t.Fatal("expected invalid service name to fail")
	}
}
