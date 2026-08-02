package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/exitcode"
	metricsexporter "github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/metrics"
)

func runMetrics(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("metrics", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultSitePath, "site configuration path")
	dsnFile := flags.String("dsn-file", "", "PostgreSQL DSN file for a read-only metrics role")
	listenAddress := flags.String("listen", "127.0.0.1:9188", "HTTP listen address")
	queryTimeout := flags.Duration("query-timeout", 10*time.Second, "maximum PostgreSQL snapshot duration")
	shutdownTimeout := flags.Duration("shutdown-timeout", 10*time.Second, "graceful shutdown timeout")
	if err := flags.Parse(args); err != nil {
		return exitcode.InvalidInput
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "metrics does not accept positional arguments")
		return exitcode.InvalidInput
	}
	if *listenAddress == "" || *queryTimeout <= 0 || *shutdownTimeout <= 0 {
		return emitFailure(stdout, stderr, false, "metrics", "invalid_input", errors.New("listen address and timeouts must be valid"), exitcode.InvalidInput)
	}

	site, err := config.LoadSite(*configPath)
	if err != nil {
		return emitFailure(stdout, stderr, false, "metrics", "invalid_input", err, exitcode.InvalidInput)
	}
	dsn := site.Database.DSN
	if *dsnFile != "" {
		dsn, err = config.ReadSecret(*dsnFile)
		if err != nil {
			return emitFailure(stdout, stderr, false, "metrics", "invalid_input", errors.New("metrics DSN file is unreadable or empty"), exitcode.InvalidInput)
		}
	}

	startupContext, startupCancel := context.WithTimeout(context.Background(), *queryTimeout)
	source, err := metricsexporter.OpenPostgres(startupContext, dsn)
	startupCancel()
	if err != nil {
		return emitFailure(stdout, stderr, false, "metrics", "dependency_unavailable", errors.New("PostgreSQL is unavailable"), exitcode.UnavailableDependency)
	}
	defer source.Close()

	listener, err := net.Listen("tcp", *listenAddress)
	if err != nil {
		return emitFailure(stdout, stderr, false, "metrics", "listen_failed", err, exitcode.UnavailableDependency)
	}
	defer listener.Close()

	exporter := metricsexporter.NewExporter(source, version, *queryTimeout)
	server := &http.Server{
		Handler:           exporter,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      *queryTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	serveErrors := make(chan error, 1)
	go func() {
		serveErrors <- server.Serve(listener)
	}()

	fmt.Fprintf(stdout, "metrics listening on http://%s/metrics\n", listener.Addr().String())

	select {
	case err := <-serveErrors:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return emitFailure(stdout, stderr, false, "metrics", "serve_failed", err, exitcode.PartialFailure)
		}
		return exitcode.OK
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), *shutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownContext); err != nil {
			return emitFailure(stdout, stderr, false, "metrics", "shutdown_failed", err, exitcode.PartialFailure)
		}
		err := <-serveErrors
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return emitFailure(stdout, stderr, false, "metrics", "serve_failed", err, exitcode.PartialFailure)
		}
		return exitcode.OK
	}
}
