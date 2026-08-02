package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/doctor"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/exitcode"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/output"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
)

const defaultSitePath = "/usr/local/etc/bkcp/site.toml"

var version = "dev"

func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		writeUsage(stderr)
		return exitcode.InvalidInput
	}
	switch args[0] {
	case "help", "-h", "--help":
		writeUsage(stdout)
		return exitcode.OK
	case "version":
		fmt.Fprintln(stdout, version)
		return exitcode.OK
	case "doctor":
		return runDoctor(args[1:], stdout, stderr)
	case "plan":
		return runPlan(args[1:], stdout, stderr)
	case "apply":
		return runApply(args[1:], stdout, stderr)
	case "reconcile":
		return runReconcile(args[1:], stdout, stderr)
	case "delete":
		return runDelete(args[1:], stdout, stderr)
	case "migrate":
		return runMigrate(args[1:], stdout, stderr)
	case "status":
		return runStatus(args[1:], stdout, stderr)
	case "inspect":
		return runInspect(args[1:], stdout, stderr)
	case "metrics":
		return runMetrics(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n", args[0])
		writeUsage(stderr)
		return exitcode.InvalidInput
	}
}

func runDoctor(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	offline := flags.Bool("offline", false, "skip live PostgreSQL, Kea, and ZFS probes")
	timeoutValue := flags.Duration("timeout", 10*time.Second, "overall probe timeout")
	if err := flags.Parse(args); err != nil {
		return exitcode.InvalidInput
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "doctor does not accept positional arguments")
		return exitcode.InvalidInput
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "doctor", "invalid_input", err, exitcode.InvalidInput)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeoutValue)
	defer cancel()
	report := doctor.Run(ctx, site, doctor.Options{Live: !*offline})
	if *jsonOutput {
		if err := output.WriteJSON(stdout, "doctor", report, nil); err != nil {
			fmt.Fprintln(stderr, err)
			return exitcode.InternalError
		}
	} else {
		writeDoctorHuman(stdout, report)
	}
	if !report.Healthy() {
		return exitcode.UnavailableDependency
	}
	return exitcode.OK
}

func runPlan(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("plan", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	manifestPath := flags.String("file", "", "VM manifest path")
	jsonOutput := flags.Bool("json", false, "emit versioned JSON")
	generationText := flags.String("generation", "1", "declared-state generation")
	if err := flags.Parse(args); err != nil {
		return exitcode.InvalidInput
	}
	if flags.NArg() != 0 || *manifestPath == "" {
		fmt.Fprintln(stderr, "plan requires --file and no positional arguments")
		return exitcode.InvalidInput
	}
	generation, err := strconv.ParseUint(*generationText, 10, 64)
	if err != nil || generation == 0 {
		return emitFailure(stdout, stderr, *jsonOutput, "plan", "invalid_input", errors.New("generation must be a positive integer"), exitcode.InvalidInput)
	}
	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "plan", "invalid_input", err, exitcode.InvalidInput)
	}
	manifest, err := config.LoadVM(*manifestPath)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "plan", "invalid_input", err, exitcode.InvalidInput)
	}
	if err := validateReferences(site, manifest); err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "plan", "invalid_input", err, exitcode.InvalidInput)
	}
	plan, err := planner.BuildApply(site.ControlPlaneID, generation, manifest)
	if err != nil {
		return emitFailure(stdout, stderr, *jsonOutput, "plan", "internal_error", err, exitcode.InternalError)
	}
	if *jsonOutput {
		if err := output.WriteJSON(stdout, "plan", plan, nil); err != nil {
			fmt.Fprintln(stderr, err)
			return exitcode.InternalError
		}
	} else {
		writePlanHuman(stdout, plan)
	}
	return exitcode.OK
}

func validateReferences(site config.Site, manifest config.VMManifest) error {
	poolFound := false
	for _, pool := range site.Pools {
		if pool.Name == manifest.Pool {
			poolFound = true
			break
		}
	}
	if !poolFound {
		return fmt.Errorf("manifest references unknown pool %q", manifest.Pool)
	}
	imageFound := false
	for _, image := range site.Images {
		if image.Name == manifest.Image {
			imageFound = true
			break
		}
	}
	if !imageFound {
		return fmt.Errorf("manifest references unknown image %q", manifest.Image)
	}
	return nil
}

func emitFailure(stdout, stderr io.Writer, jsonOutput bool, command, code string, err error, exit int) int {
	if jsonOutput {
		if outputErr := output.WriteError(stdout, command, code, err); outputErr != nil {
			fmt.Fprintln(stderr, outputErr)
			return exitcode.InternalError
		}
	} else {
		fmt.Fprintln(stderr, err)
	}
	return exit
}

func writeDoctorHuman(w io.Writer, report doctor.Report) {
	for _, check := range report.Checks {
		fmt.Fprintf(w, "%-5s %-28s %s\n", check.Status, check.Name, check.Detail)
	}
}

func writePlanHuman(w io.Writer, plan planner.Plan) {
	fmt.Fprintf(w, "resource: %s\n", plan.Resource)
	fmt.Fprintf(w, "generation: %d\n", plan.Generation)
	fmt.Fprintf(w, "spec_digest: %s\n", plan.SpecDigest)
	fmt.Fprintf(w, "plan_digest: %s\n", plan.PlanDigest)
	fmt.Fprintf(w, "idempotency_key: %s\n", plan.IdempotencyKey)
	for _, step := range plan.Steps {
		fmt.Fprintf(w, "%d. %s %s %s\n", step.Sequence, step.Driver, step.Action, step.InputDigest)
	}
}

func writeUsage(w io.Writer) {
	fmt.Fprintln(w, "cpctl - declarative FreeBSD bhyve + Kea control plane")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Usage:")
	fmt.Fprintln(w, "  cpctl doctor [--config PATH] [--offline] [--json]")
	fmt.Fprintln(w, "  cpctl plan --file VM.toml [--config PATH] [--generation N] [--json]")
	fmt.Fprintln(w, "  cpctl apply --file VM.toml [--config PATH] [--json]")
	fmt.Fprintln(w, "  cpctl reconcile NAME [--config PATH] [--json]")
	fmt.Fprintln(w, "  cpctl delete NAME --destroy-storage [--config PATH] [--json]")
	fmt.Fprintln(w, "  cpctl migrate [--config PATH] [--dry-run] [--json]")
	fmt.Fprintln(w, "  cpctl status [--config PATH] [--json]")
	fmt.Fprintln(w, "  cpctl inspect NAME [--config PATH] [--json]")
	fmt.Fprintln(w, "  cpctl metrics [--config PATH] [--dsn-file PATH] [--listen ADDRESS]")
	fmt.Fprintln(w, "  cpctl version")
}
