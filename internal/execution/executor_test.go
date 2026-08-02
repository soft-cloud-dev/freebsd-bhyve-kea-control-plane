package execution

import (
	"context"
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

type fakeRepository struct {
	inspection state.Inspection
	steps      []state.OperationStep
	claimed    []int
	completed  []int
	locked     bool
	unlocked   bool
	finished   bool
}

func (f *fakeRepository) InspectResource(context.Context, string) (state.Inspection, error) {
	return f.inspection, nil
}
func (f *fakeRepository) LockExecution(context.Context, string) (func(), error) {
	f.locked = true
	return func() { f.unlocked = true }, nil
}
func (f *fakeRepository) StartOperation(context.Context, string) error { return nil }
func (f *fakeRepository) ExecutionSteps(context.Context, string) ([]state.OperationStep, error) {
	return f.steps, nil
}
func (f *fakeRepository) ClaimStep(_ context.Context, _ string, sequence int) (state.OperationStep, error) {
	f.claimed = append(f.claimed, sequence)
	for _, step := range f.steps {
		if step.Sequence == sequence {
			return step, nil
		}
	}
	panic("missing step")
}
func (f *fakeRepository) CompleteStep(_ context.Context, _ string, sequence int, _ any, _ bool) error {
	f.completed = append(f.completed, sequence)
	return nil
}
func (f *fakeRepository) FailStep(context.Context, string, int, string, string, bool) error {
	return nil
}
func (f *fakeRepository) CompleteOperation(context.Context, string, string, string) error {
	f.finished = true
	return nil
}
func (f *fakeRepository) RecordObservation(context.Context, state.Observation) error { return nil }

type fakeDriver struct{ calls []int }

func (f *fakeDriver) Ensure(_ context.Context, input planner.StepInput) (Result, error) {
	f.calls = append(f.calls, input.Sequence)
	return Result{Postcondition: map[string]any{"sequence": input.Sequence}}, nil
}

func TestExecutorResumesAtFirstIncompleteStep(t *testing.T) {
	firstInput := planner.StepInput{Schema: 1, Operation: "apply", Sequence: 1, Driver: "image", Action: "ensure-verified", Resource: "node-01", Generation: 1}
	firstJSON, firstDigest, err := planner.DigestStepInput(firstInput)
	if err != nil {
		t.Fatal(err)
	}
	secondInput := firstInput
	secondInput.Sequence = 2
	secondInput.Driver = "zfs"
	secondInput.Action = "ensure-storage"
	secondJSON, secondDigest, err := planner.DigestStepInput(secondInput)
	if err != nil {
		t.Fatal(err)
	}
	repo := &fakeRepository{
		inspection: state.Inspection{Resource: state.ResourceSummary{UUID: "resource-1", Name: "node-01"}, Operation: &state.Operation{UUID: "operation-1", Action: "apply", Status: "failed", PlanDigest: "plan"}},
		steps: []state.OperationStep{
			{OperationUUID: "operation-1", Sequence: 1, Driver: "image", Action: "ensure-verified", InputDigest: firstDigest, InputJSON: firstJSON, Status: "succeeded"},
			{OperationUUID: "operation-1", Sequence: 2, Driver: "zfs", Action: "ensure-storage", InputDigest: secondDigest, InputJSON: secondJSON, Status: "failed"},
		},
	}
	driver := &fakeDriver{}
	_, err = (Executor{Repository: repo, Driver: driver}).Run(context.Background(), "node-01")
	if err != nil {
		t.Fatal(err)
	}
	if len(driver.calls) != 1 || driver.calls[0] != 2 {
		t.Fatalf("driver calls: %#v", driver.calls)
	}
	if len(repo.claimed) != 1 || repo.claimed[0] != 2 || !repo.finished {
		t.Fatalf("repo state: %#v", repo)
	}
	if !repo.locked || !repo.unlocked {
		t.Fatalf("execution lock was not held and released: %#v", repo)
	}
}

func TestExecutorBlocksTamperedInput(t *testing.T) {
	input := planner.StepInput{Schema: 1, Operation: "apply", Sequence: 1, Driver: "image", Action: "ensure-verified", Resource: "node-01", Generation: 1}
	inputJSON, digest, err := planner.DigestStepInput(input)
	if err != nil {
		t.Fatal(err)
	}
	repo := &fakeRepository{
		inspection: state.Inspection{Resource: state.ResourceSummary{UUID: "resource-1", Name: "node-01"}, Operation: &state.Operation{UUID: "operation-1", Action: "apply", Status: "pending"}},
		steps:      []state.OperationStep{{OperationUUID: "operation-1", Sequence: 1, Driver: "image", Action: "ensure-verified", InputDigest: digest, InputJSON: inputJSON + " ", Status: "pending"}},
	}
	_, err = (Executor{Repository: repo, Driver: &fakeDriver{}}).Run(context.Background(), "node-01")
	if err == nil {
		t.Fatal("expected tampered input to fail")
	}
	if !repo.unlocked {
		t.Fatal("execution lock was not released after failure")
	}
}
