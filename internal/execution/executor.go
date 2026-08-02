package execution

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

type Repository interface {
	InspectResource(context.Context, string) (state.Inspection, error)
	LockExecution(context.Context, string) (func(), error)
	StartOperation(context.Context, string) error
	ClaimStep(context.Context, string, int) (state.OperationStep, error)
	CompleteStep(context.Context, string, int, any, bool) error
	FailStep(context.Context, string, int, string, string, bool) error
	CompleteOperation(context.Context, string, string, string) error
	RecordObservation(context.Context, state.Observation) error
	ExecutionSteps(context.Context, string) ([]state.OperationStep, error)
}

type Result struct {
	Postcondition any
	Skipped       bool
	Observation   *state.Observation
}

type Driver interface {
	Ensure(context.Context, planner.StepInput) (Result, error)
}

type Executor struct {
	Repository Repository
	Driver     Driver
}

func (e Executor) Run(ctx context.Context, resourceName string) (state.Inspection, error) {
	inspection, err := e.Repository.InspectResource(ctx, resourceName)
	if err != nil {
		return state.Inspection{}, err
	}
	unlock, err := e.Repository.LockExecution(ctx, inspection.Resource.UUID)
	if err != nil {
		return state.Inspection{}, err
	}
	defer unlock()

	inspection, err = e.Repository.InspectResource(ctx, resourceName)
	if err != nil {
		return state.Inspection{}, err
	}
	if inspection.Operation == nil {
		return state.Inspection{}, fmt.Errorf("%w: resource has no prepared operation", state.ErrBlocked)
	}
	operation := *inspection.Operation
	if operation.Status == "succeeded" {
		return inspection, nil
	}
	steps, err := e.Repository.ExecutionSteps(ctx, operation.UUID)
	if err != nil {
		return state.Inspection{}, err
	}
	if err := e.Repository.StartOperation(ctx, operation.UUID); err != nil {
		return state.Inspection{}, err
	}
	for _, persisted := range steps {
		if persisted.Status == "succeeded" || persisted.Status == "skipped" {
			continue
		}
		claimed, err := e.Repository.ClaimStep(ctx, operation.UUID, persisted.Sequence)
		if err != nil {
			return state.Inspection{}, err
		}
		var input planner.StepInput
		if err := json.Unmarshal([]byte(claimed.InputJSON), &input); err != nil {
			_ = e.Repository.FailStep(ctx, operation.UUID, claimed.Sequence, "invalid_step_input", err.Error(), true)
			return state.Inspection{}, fmt.Errorf("decode step %d input: %w", claimed.Sequence, err)
		}
		canonical, digest, err := planner.DigestStepInput(input)
		if err != nil || canonical != claimed.InputJSON || digest != claimed.InputDigest {
			detail := "persisted step input digest does not match"
			if err != nil {
				detail = err.Error()
			}
			_ = e.Repository.FailStep(ctx, operation.UUID, claimed.Sequence, "step_input_mismatch", detail, true)
			return state.Inspection{}, fmt.Errorf("%w: %s", state.ErrBlocked, detail)
		}
		result, driverErr := e.Driver.Ensure(ctx, input)
		if result.Observation != nil {
			result.Observation.ResourceUUID = inspection.Resource.UUID
			result.Observation.PlanDigest = operation.PlanDigest
			if err := e.Repository.RecordObservation(ctx, *result.Observation); err != nil {
				_ = e.Repository.FailStep(ctx, operation.UUID, claimed.Sequence, "observation_persist_failed", err.Error(), false)
				return state.Inspection{}, err
			}
		}
		if driverErr != nil {
			blocked := errors.Is(driverErr, state.ErrBlocked)
			code := "driver_failed"
			if blocked {
				code = "driver_blocked"
			}
			_ = e.Repository.FailStep(ctx, operation.UUID, claimed.Sequence, code, driverErr.Error(), blocked)
			return state.Inspection{}, fmt.Errorf("step %d %s/%s: %w", claimed.Sequence, claimed.Driver, claimed.Action, driverErr)
		}
		postcondition := result.Postcondition
		if postcondition == nil {
			postcondition = map[string]any{"satisfied": true}
		}
		if err := e.Repository.CompleteStep(ctx, operation.UUID, claimed.Sequence, postcondition, result.Skipped); err != nil {
			return state.Inspection{}, err
		}
	}
	effective := "converged"
	if operation.Action == "delete" {
		effective = "absent"
	}
	if err := e.Repository.CompleteOperation(ctx, operation.UUID, inspection.Resource.UUID, effective); err != nil {
		return state.Inspection{}, err
	}
	if operation.Action == "delete" {
		operation.Status = "succeeded"
		inspection.Operation = &operation
		inspection.Resource.EffectiveState = "absent"
		inspection.Resource.OperationStatus = "succeeded"
		inspection.Effective = &state.Effective{State: "absent", CurrentPlanDigest: operation.PlanDigest}
		inspection.ResumeStep = nil
		return inspection, nil
	}
	return e.Repository.InspectResource(ctx, resourceName)
}
