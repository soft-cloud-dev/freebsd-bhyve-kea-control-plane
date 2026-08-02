package metrics

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestObservabilityAssets(t *testing.T) {
	root := filepath.Join("..", "..")
	dashboardPath := filepath.Join(root, "observability", "grafana", "dashboards", "bkcp-overview.json")
	dashboardBytes, err := os.ReadFile(dashboardPath)
	if err != nil {
		t.Fatal(err)
	}
	var dashboard struct {
		UID    string            `json:"uid"`
		Title  string            `json:"title"`
		Panels []json.RawMessage `json:"panels"`
	}
	if err := json.Unmarshal(dashboardBytes, &dashboard); err != nil {
		t.Fatalf("invalid Grafana dashboard JSON: %v", err)
	}
	if dashboard.UID != "bkcp-overview" || dashboard.Title == "" || len(dashboard.Panels) < 8 {
		t.Fatalf("incomplete dashboard: %#v", dashboard)
	}

	checks := []struct {
		path     string
		required []string
	}{
		{
			path: filepath.Join(root, "observability", "prometheus", "prometheus.yml"),
			required: []string{
				"job_name: bkcp",
				"127.0.0.1:9188",
				"bkcp.rules.yml",
			},
		},
		{
			path: filepath.Join(root, "observability", "prometheus", "bkcp.rules.yml"),
			required: []string{
				"BKCPExporterDown",
				"BKCPResourceNotConverged",
				"BKCPObservationUnavailable",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana", "provisioning", "datasources", "bkcp-prometheus.yml"),
			required: []string{
				"uid: bkcp-prometheus",
				"type: prometheus",
				"http://127.0.0.1:9090",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana", "provisioning", "dashboards", "bkcp.yml"),
			required: []string{
				"folderUid: bkcp",
				"type: file",
				"/var/db/grafana/dashboards/bkcp",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana-cloud", "postgres", "config.alloy"),
			required: []string{
				"database_observability.postgres \"postgres_bkcp\"",
				"prometheus.exporter.postgres \"postgres_bkcp\"",
				"enabled_collectors = [\"stat_statements\"]",
				"disable_query_redaction = false",
				"disable_collectors",
				"[\"logs\"]",
				"integrations/db-o11y",
				"target_label  = \"dsn\"",
				"prometheus.remote_write \"metrics_service\"",
				"loki.write \"logs_service\"",
				"127.0.0.1:9188",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana-cloud", "postgres", "postgresql.conf.example"),
			required: []string{
				"shared_preload_libraries = 'pg_stat_statements'",
				"compute_query_id = on",
				"pg_stat_statements.track = all",
				"track_activity_query_size = 4096",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana-cloud", "postgres", "grants.sql"),
			required: []string{
				"CREATE EXTENSION IF NOT EXISTS pg_stat_statements",
				"GRANT pg_monitor TO \"db-o11y\"",
				"GRANT pg_read_all_stats TO \"db-o11y\"",
				"GRANT USAGE ON SCHEMA bkcp TO \"db-o11y\"",
				"ALTER ROLE \"db-o11y\" SET pg_stat_statements.track = 'none'",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana-cloud", "postgres", "alloy.env.example"),
			required: []string{
				"BKCP_DB_INSTANCE=",
				"GCLOUD_HOSTED_METRICS_URL=",
				"GCLOUD_HOSTED_METRICS_ID=",
				"GCLOUD_HOSTED_LOGS_URL=",
				"GCLOUD_HOSTED_LOGS_ID=",
				"GCLOUD_RW_API_KEY=",
			},
		},
		{
			path: filepath.Join(root, "observability", "grafana-cloud", "postgres", "README.md"),
			required: []string{
				"Grafana Cloud PostgreSQL Database Observability",
				"Alloy 1.17.0 or later",
				"PgBouncer",
				"metrics:write",
				"logs:write",
			},
		},
	}
	for _, check := range checks {
		content, err := os.ReadFile(check.path)
		if err != nil {
			t.Fatal(err)
		}
		for _, required := range check.required {
			if !strings.Contains(string(content), required) {
				t.Fatalf("%s does not contain %q", check.path, required)
			}
		}
	}

	for _, rcScript := range []string{
		filepath.Join(root, "config", "rc.d", "bkcp_metrics"),
		filepath.Join(root, "config", "rc.d", "bkcp_alloy"),
	} {
		if output, err := exec.Command("sh", "-n", rcScript).CombinedOutput(); err != nil {
			t.Fatalf("invalid rc.d script %s: %v: %s", rcScript, err, output)
		}
	}
}
