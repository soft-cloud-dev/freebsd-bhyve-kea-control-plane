package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/exitcode"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/migrate"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/output"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
	statepg "github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state/postgres"
)

func runMigrate(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("migrate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	dryRun := flags.Bool("dry-run", false, "report pending migrations without modifying PostgreSQL")
	timeout := flags.Duration("timeout", 30*time.Second, "database operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return exitcode.InvalidInput
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "migrate", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	conn, err := migrate.Connect(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "migrate", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer conn.Close(ctx)
	runner, err := migrate.New()
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "migrate", "internal_error", err, exitcode.InternalError)
	}
	var data any
	if *dryRun {
		data, err = runner.Plan(ctx, conn)
	} else {
		data, err = runner.Run(ctx, conn)
	}
	if err != nil {
		code := exitcode.InternalError
		errorCode := "internal_error"
		if errors.Is(err, migrate.ErrChecksumMismatch) {
			code = exitcode.BlockedOperation
			errorCode = "migration_checksum_mismatch"
		}
		return emitFailure(stdout, stderr, *jsonOutput, "migrate", errorCode, err, code)
	}
	if *jsonOutput {
		if err := output.WriteJSON(stdout, "migrate", data, nil); err != nil {
			return exitcode.InternalError
		}
	} else {
		fmt.Fprintf(stdout, "%+v\n", data)
	}
	return exitcode.OK
}

func runStatus(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("status", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	timeout := flags.Duration("timeout", 15*time.Second, "database operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return exitcode.InvalidInput
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "status", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	repo, err := statepg.Open(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "status", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer repo.Close()
	items, err := repo.ListResources(ctx)
	if err != nil {
		return stateFailure(stdout, stderr, *jsonOutput, "status", err)
	}
	if *jsonOutput {
		if err := output.WriteJSON(stdout, "status", items, nil); err != nil {
			return exitcode.InternalError
		}
	} else {
		fmt.Fprintln(stdout, "NAME\tGENERATION\tEFFECTIVE\tOPERATION")
		for _, item := range items {
			fmt.Fprintf(stdout, "%s\t%d\t%s\t%s\n", item.Name, item.Generation, item.EffectiveState, item.OperationStatus)
		}
	}
	return exitcode.OK
}

func runInspect(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("inspect", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	timeout := flags.Duration("timeout", 15*time.Second, "database operation timeout")
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 {
		fmt.Fprintln(stderr, "inspect requires one resource name")
		return exitcode.InvalidInput
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "inspect", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	repo, err := statepg.Open(ctx, site.Database.DSN)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "inspect", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer repo.Close()
	inspection, err := repo.InspectResource(ctx, flags.Arg(0))
	if err != nil {
		if errors.Is(err, state.ErrNotFound) {
			return emitFailure(stdout, stderr, *jsonOutput, "inspect", "not_found", err, exitcode.NotFound)
		}
		return stateFailure(stdout, stderr, *jsonOutput, "inspect", err)
	}
	if *jsonOutput {
		if err := output.WriteJSON(stdout, "inspect", inspection, nil); err != nil {
			return exitcode.InternalError
		}
	} else {
		fmt.Fprintf(stdout, "resource: %s\ngeneration: %d\neffective: %s\noperation: %s\n", inspection.Resource.Name, inspection.Resource.Generation, inspection.Resource.EffectiveState, inspection.Resource.OperationStatus)
		if inspection.ResumeStep != nil {
			fmt.Fprintf(stdout, "resume_step: %d %s %s\n", inspection.ResumeStep.Sequence, inspection.ResumeStep.Driver, inspection.ResumeStep.Action)
		}
	}
	return exitcode.OK
}

func stateFailure(stdout, stderr io.Writer, jsonOutput bool, command string, err error) int {
	if statepg.IsSchemaMissing(err) {
		return emitFailure(stdout, stderr, jsonOutput, command, "schema_missing", errors.New("V2 schema is missing; run cpctl migrate"), exitcode.BlockedOperation)
	}
	return emitFailure(stdout, stderr, jsonOutput, command, "internal_error", err, exitcode.InternalError)
}
