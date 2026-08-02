package metrics

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const prometheusContentType = "text/plain; version=0.0.4; charset=utf-8"

type Exporter struct {
	Source       Source
	Version      string
	QueryTimeout time.Duration

	scrapes     atomic.Uint64
	failures    atomic.Uint64
	lastSuccess atomic.Int64
}

func NewExporter(source Source, version string, queryTimeout time.Duration) *Exporter {
	if queryTimeout <= 0 {
		queryTimeout = 10 * time.Second
	}
	if version == "" {
		version = "dev"
	}
	return &Exporter{Source: source, Version: version, QueryTimeout: queryTimeout}
}

func (e *Exporter) ServeHTTP(w http.ResponseWriter, request *http.Request) {
	switch request.URL.Path {
	case "/metrics":
		e.serveMetrics(w, request)
	case "/-/healthy":
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
	case "/-/ready":
		e.serveReady(w, request)
	default:
		http.NotFound(w, request)
	}
}

func (e *Exporter) serveReady(w http.ResponseWriter, request *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if e.Source == nil {
		http.Error(w, "metrics source unavailable", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), e.QueryTimeout)
	defer cancel()
	if err := e.Source.Ping(ctx); err != nil {
		http.Error(w, "PostgreSQL unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ready\n")
}

func (e *Exporter) serveMetrics(w http.ResponseWriter, request *http.Request) {
	started := time.Now()
	e.scrapes.Add(1)
	w.Header().Set("Content-Type", prometheusContentType)
	w.Header().Set("Cache-Control", "no-store")

	if e.Source == nil {
		e.failures.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		e.renderSelf(w, 0, time.Since(started), time.Time{})
		return
	}

	ctx, cancel := context.WithTimeout(request.Context(), e.QueryTimeout)
	defer cancel()
	snapshot, err := e.Source.Snapshot(ctx)
	if err != nil {
		e.failures.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		e.renderSelf(w, 0, time.Since(started), time.Time{})
		return
	}

	now := time.Now().UTC()
	e.lastSuccess.Store(now.Unix())
	w.WriteHeader(http.StatusOK)
	e.renderSelf(w, 1, time.Since(started), snapshot.CollectedAt)
	renderSnapshot(w, snapshot)
}

func (e *Exporter) renderSelf(w io.Writer, success float64, duration time.Duration, collectedAt time.Time) {
	writeHelpType(w, "bkcp_exporter_info", "Build information for the cpctl metrics exporter.", "gauge")
	writeMetric(w, "bkcp_exporter_info", []label{{"version", e.Version}}, 1)
	writeHelpType(w, "bkcp_exporter_scrapes_total", "Total Prometheus scrape attempts.", "counter")
	writeMetric(w, "bkcp_exporter_scrapes_total", nil, float64(e.scrapes.Load()))
	writeHelpType(w, "bkcp_exporter_scrape_failures_total", "Total failed Prometheus scrape attempts.", "counter")
	writeMetric(w, "bkcp_exporter_scrape_failures_total", nil, float64(e.failures.Load()))
	writeHelpType(w, "bkcp_exporter_scrape_success", "Whether the current snapshot collection succeeded.", "gauge")
	writeMetric(w, "bkcp_exporter_scrape_success", nil, success)
	writeHelpType(w, "bkcp_exporter_scrape_duration_seconds", "Duration of the current snapshot collection.", "gauge")
	writeMetric(w, "bkcp_exporter_scrape_duration_seconds", nil, duration.Seconds())
	writeHelpType(w, "bkcp_exporter_last_success_timestamp_seconds", "Unix timestamp of the last successful snapshot collection.", "gauge")
	writeMetric(w, "bkcp_exporter_last_success_timestamp_seconds", nil, float64(e.lastSuccess.Load()))
	writeHelpType(w, "bkcp_exporter_snapshot_collected_timestamp_seconds", "Unix timestamp represented by the current database snapshot.", "gauge")
	value := float64(0)
	if !collectedAt.IsZero() {
		value = float64(collectedAt.Unix())
	}
	writeMetric(w, "bkcp_exporter_snapshot_collected_timestamp_seconds", nil, value)
}

func renderSnapshot(w io.Writer, snapshot Snapshot) {
	writeHelpType(w, "bkcp_resource_info", "Static labels for an active V2 resource.", "gauge")
	writeHelpType(w, "bkcp_resource_generation", "Current declared generation for a resource.", "gauge")
	writeHelpType(w, "bkcp_resource_effective_state", "Current effective state for a resource.", "gauge")
	writeHelpType(w, "bkcp_resource_observation_state", "Latest authoritative observation state by domain.", "gauge")
	writeHelpType(w, "bkcp_resource_last_observation_timestamp_seconds", "Unix timestamp of the latest observation.", "gauge")
	writeHelpType(w, "bkcp_resource_last_successful_reconciliation_timestamp_seconds", "Unix timestamp of the last successful reconciliation.", "gauge")
	writeHelpType(w, "bkcp_resource_latest_operation_info", "Latest operation action and status for a resource.", "gauge")
	writeHelpType(w, "bkcp_resource_latest_operation_attempts", "Attempt count of the latest operation for a resource.", "gauge")

	domains := []string{"image", "kea", "pf", "power", "seed", "storage", "vm"}
	for _, resource := range snapshot.Resources {
		managed := "false"
		if resource.Managed {
			managed = "true"
		}
		writeMetric(w, "bkcp_resource_info", []label{
			{"name", resource.Name},
			{"managed", managed},
			{"pool", resource.Pool},
			{"image", resource.Image},
			{"desired_power", resource.DesiredPower},
		}, 1)
		writeMetric(w, "bkcp_resource_generation", []label{{"name", resource.Name}}, float64(resource.Generation))
		writeMetric(w, "bkcp_resource_effective_state", []label{{"name", resource.Name}, {"state", resource.EffectiveState}}, 1)
		for _, domain := range domains {
			state := resource.ObservationStates[domain]
			if state == "" {
				state = "unknown"
			}
			writeMetric(w, "bkcp_resource_observation_state", []label{{"name", resource.Name}, {"domain", domain}, {"state", state}}, 1)
		}
		if resource.ObservationCollectedAt != nil {
			writeMetric(w, "bkcp_resource_last_observation_timestamp_seconds", []label{{"name", resource.Name}}, float64(resource.ObservationCollectedAt.Unix()))
		}
		if resource.LastSuccessfulReconciliationAt != nil {
			writeMetric(w, "bkcp_resource_last_successful_reconciliation_timestamp_seconds", []label{{"name", resource.Name}}, float64(resource.LastSuccessfulReconciliationAt.Unix()))
		}
		if resource.LatestOperationAction != "" || resource.LatestOperationStatus != "" {
			writeMetric(w, "bkcp_resource_latest_operation_info", []label{
				{"name", resource.Name},
				{"action", resource.LatestOperationAction},
				{"status", resource.LatestOperationStatus},
			}, 1)
			writeMetric(w, "bkcp_resource_latest_operation_attempts", []label{{"name", resource.Name}}, float64(resource.LatestOperationAttempts))
		}
	}

	writeHelpType(w, "bkcp_operations", "Number of journaled operations by action and status.", "gauge")
	for _, item := range snapshot.OperationCounts {
		writeMetric(w, "bkcp_operations", []label{{"action", item.Action}, {"status", item.Status}}, float64(item.Count))
	}

	writeHelpType(w, "bkcp_operation_steps", "Number of journaled operation steps by driver, action, and status.", "gauge")
	for _, item := range snapshot.StepCounts {
		writeMetric(w, "bkcp_operation_steps", []label{{"driver", item.Driver}, {"action", item.Action}, {"status", item.Status}}, float64(item.Count))
	}

	writeHelpType(w, "bkcp_allocations", "Number of durable allocations by pool and release state.", "gauge")
	for _, item := range snapshot.AllocationCounts {
		writeMetric(w, "bkcp_allocations", []label{{"pool", item.Pool}, {"state", item.State}}, float64(item.Count))
	}
}

type label struct {
	name  string
	value string
}

func writeHelpType(w io.Writer, name, help, metricType string) {
	_, _ = fmt.Fprintf(w, "# HELP %s %s\n", name, help)
	_, _ = fmt.Fprintf(w, "# TYPE %s %s\n", name, metricType)
}

func writeMetric(w io.Writer, name string, labels []label, value float64) {
	_, _ = io.WriteString(w, name)
	if len(labels) > 0 {
		sort.SliceStable(labels, func(i, j int) bool { return labels[i].name < labels[j].name })
		_, _ = io.WriteString(w, "{")
		for index, item := range labels {
			if index > 0 {
				_, _ = io.WriteString(w, ",")
			}
			_, _ = fmt.Fprintf(w, "%s=\"%s\"", item.name, escapeLabel(item.value))
		}
		_, _ = io.WriteString(w, "}")
	}
	_, _ = io.WriteString(w, " ")
	_, _ = io.WriteString(w, strconv.FormatFloat(value, 'g', -1, 64))
	_, _ = io.WriteString(w, "\n")
}

func escapeLabel(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\n", "\\n")
	return strings.ReplaceAll(value, "\"", "\\\"")
}
