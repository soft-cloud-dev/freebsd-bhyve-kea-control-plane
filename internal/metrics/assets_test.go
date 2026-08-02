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

	rcScript := filepath.Join(root, "config", "rc.d", "bkcp_metrics")
	if output, err := exec.Command("sh", "-n", rcScript).CombinedOutput(); err != nil {
		t.Fatalf("invalid rc.d script: %v: %s", err, output)
	}
}
