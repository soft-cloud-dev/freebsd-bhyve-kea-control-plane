package metrics

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeSource struct {
	snapshot Snapshot
	snapErr  error
	pingErr  error
}

func (f fakeSource) Snapshot(context.Context) (Snapshot, error) {
	return f.snapshot, f.snapErr
}

func (f fakeSource) Ping(context.Context) error {
	return f.pingErr
}

func TestExporterRendersResourceAndJournalMetrics(t *testing.T) {
	observedAt := time.Unix(100, 0).UTC()
	reconciledAt := time.Unix(90, 0).UTC()
	exporter := NewExporter(fakeSource{snapshot: Snapshot{
		CollectedAt: time.Unix(110, 0).UTC(),
		Resources: []Resource{{
			Name:                           "node-01",
			Managed:                        true,
			Generation:                     3,
			EffectiveState:                 "converged",
			DesiredPower:                   "running",
			Pool:                           "vm-lan",
			Image:                          "freebsd\"14",
			LastSuccessfulReconciliationAt: &reconciledAt,
			ObservationCollectedAt:         &observedAt,
			ObservationStates: map[string]string{
				"vm": "present", "storage": "present", "kea": "present",
				"seed": "present", "image": "present", "pf": "present", "power": "running",
			},
			LatestOperationAction:   "apply",
			LatestOperationStatus:   "succeeded",
			LatestOperationAttempts: 1,
		}},
		OperationCounts:  []OperationCount{{Action: "apply", Status: "succeeded", Count: 2}},
		StepCounts:       []StepCount{{Driver: "zfs", Action: "ensure-storage", Status: "succeeded", Count: 2}},
		AllocationCounts: []AllocationCount{{Pool: "vm-lan", State: "active", Count: 1}},
	}}, "test-version", time.Second)

	request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	response := httptest.NewRecorder()
	exporter.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	body := response.Body.String()
	checks := []string{
		`bkcp_exporter_info{version="test-version"} 1`,
		`bkcp_resource_info{desired_power="running",image="freebsd\"14",managed="true",name="node-01",pool="vm-lan"} 1`,
		`bkcp_resource_effective_state{name="node-01",state="converged"} 1`,
		`bkcp_resource_observation_state{domain="power",name="node-01",state="running"} 1`,
		`bkcp_operations{action="apply",status="succeeded"} 2`,
		`bkcp_operation_steps{action="ensure-storage",driver="zfs",status="succeeded"} 2`,
		`bkcp_allocations{pool="vm-lan",state="active"} 1`,
	}
	for index, expected := range checks {
		checks[index] = strings.ReplaceAll(expected, `\"`, `"`)
	}
	for _, expected := range checks {
		if !strings.Contains(body, expected) {
			t.Fatalf("missing %q in:\n%s", expected, body)
		}
	}
}

func TestExporterReturnsServiceUnavailableWhenSnapshotFails(t *testing.T) {
	exporter := NewExporter(fakeSource{snapErr: errors.New("database failed")}, "test", time.Second)
	request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	response := httptest.NewRecorder()
	exporter.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d", response.Code)
	}
	if !strings.Contains(response.Body.String(), "bkcp_exporter_scrape_success 0") {
		t.Fatalf("failure metric missing: %s", response.Body.String())
	}
}

func TestExporterReadinessUsesPostgreSQLPing(t *testing.T) {
	exporter := NewExporter(fakeSource{pingErr: errors.New("offline")}, "test", time.Second)
	request := httptest.NewRequest(http.MethodGet, "/-/ready", nil)
	response := httptest.NewRecorder()
	exporter.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d", response.Code)
	}

	exporter = NewExporter(fakeSource{}, "test", time.Second)
	response = httptest.NewRecorder()
	exporter.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("ready status = %d", response.Code)
	}
}
