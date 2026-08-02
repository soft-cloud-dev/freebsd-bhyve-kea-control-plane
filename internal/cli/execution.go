package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/allocation"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/execution"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/exitcode"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/output"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
	statepg "github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state/postgres"
)

func runApply(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("apply", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	manifestPath := flags.String("file", "", "VM manifest path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	timeout := flags.Duration("timeout", 2*time.Hour, "operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *manifestPath == "" {
		fmt.Fprintln(stderr, "apply requires --file and no positional arguments")
		return exitcode.InvalidInput
	}
	site, manifest, err := loadExecutionInput(*configPath, *manifestPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "apply", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	repo, err := statepg.Open(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "apply", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer repo.Close()
	prepared, err := repo.PrepareExecutableApply(ctx, site, *manifestPath, manifest)
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "apply", err)
	}
	runner := execution.Executor{Repository: repo, Driver: execution.NewSystemDriver()}
	inspection, err := runner.Run(ctx, prepared.Resource.Name)
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "apply", err)
	}
	return emitExecutionResult(stdout, stderr, *jsonOutput, "apply", inspection)
}

func runReconcile(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("reconcile", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	timeout := flags.Duration("timeout", 30*time.Minute, "operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 {
		fmt.Fprintln(stderr, "reconcile requires one resource name")
		return exitcode.InvalidInput
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "reconcile", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	repo, err := statepg.Open(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "reconcile", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer repo.Close()
	prepared, err := repo.PrepareExecutableReconcile(ctx, site, flags.Arg(0))
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "reconcile", err)
	}
	runner := execution.Executor{Repository: repo, Driver: execution.NewSystemDriver()}
	inspection, err := runner.Run(ctx, prepared.Resource.Name)
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "reconcile", err)
	}
	return emitExecutionResult(stdout, stderr, *jsonOutput, "reconcile", inspection)
}

func runDelete(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("delete", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	destroyStorage := flags.Bool("destroy-storage", false, "authorize destructive ZFS removal")
	timeout := flags.Duration("timeout", 2*time.Hour, "operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 {
		fmt.Fprintln(stderr, "delete requires one resource name")
		return exitcode.InvalidInput
	}
	if !*destroyStorage {
		return emitFailure(stdout, stderr, *jsonOutput, "delete", "storage_authorization_required", errors.New("delete requires --destroy-storage"), exitcode.BlockedOperation)
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "delete", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	repo, err := statepg.Open(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "delete", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer repo.Close()
	prepared, err := repo.PrepareExecutableDelete(ctx, site, flags.Arg(0), true)
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "delete", err)
	}
	runner := execution.Executor{Repository: repo, Driver: execution.NewSystemDriver()}
	inspection, err := runner.Run(ctx, prepared.Resource.Name)
	if err != nil {
		return executionFailure(stdout, stderr, *jsonOutput, "delete", err)
	}
	return emitExecutionResult(stdout, stderr, *jsonOutput, "delete", inspection)
}

func loadExecutionInput(sitePath, manifestPath string) (config.Site, config.VMManifest, error) {
	site, err := config.LoadSite(sitePath)
	if err != nil {
		return config.Site{}, config.VMManifest{}, err
	}
	manifest, err := config.LoadVM(manifestPath)
	if err != nil {
		return config.Site{}, config.VMManifest{}, err
	}
	if err := validateReferences(site, manifest); err != nil {
		return config.Site{}, config.VMManifest{}, err
	}
	return site, manifest, nil
}

func executionFailure(stdout, stderr io.Writer, jsonOutput bool, command string, err error) int {
	switch {
	case errors.Is(err, state.ErrNotFound):
		return emitFailure(stdout, stderr, jsonOutput, command, "not_found", err, exitcode.NotFound)
	case errors.Is(err, state.ErrDrift):
		return emitFailure(stdout, stderr, jsonOutput, command, "drift_detected", err, exitcode.DriftDetected)
	case errors.Is(err, state.ErrBlocked), errors.Is(err, allocation.ErrExhausted):
		return emitFailure(stdout, stderr, jsonOutput, command, "operation_blocked", err, exitcode.BlockedOperation)
	case statepg.IsSchemaMissing(err):
		return emitFailure(stdout, stderr, jsonOutput, command, "schema_missing", errors.New("V2 schema is missing or outdated; run cpctl migrate"), exitcode.BlockedOperation)
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		return emitFailure(stdout, stderr, jsonOutput, command, "operation_incomplete", err, exitcode.PartialFailure)
	default:
		return emitFailure(stdout, stderr, jsonOutput, command, "operation_failed", err, exitcode.PartialFailure)
	}
}

func emitExecutionResult(stdout, stderr io.Writer, jsonOutput bool, command string, inspection state.Inspection) int {
	if jsonOutput {
		if err := output.WriteJSON(stdout, command, inspection, nil); err != nil {
			fmt.Fprintln(stderr, err)
			return exitcode.InternalError
		}
	} else {
		fmt.Fprintf(stdout, "resource: %s\ngeneration: %d\neffective: %s\noperation: %s\n", inspection.Resource.Name, inspection.Resource.Generation, inspection.Resource.EffectiveState, inspection.Resource.OperationStatus)
	}
	return exitcode.OK
}
