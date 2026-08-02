package doctor

import (
	"context"
	"errors"
	"testing"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

type fakeRunner struct{}

func (fakeRunner) LookPath(file string) (string, error) { return "/usr/local/bin/" + file, nil }
func (fakeRunner) Run(context.Context, string, ...string) ([]byte, error) {
	return nil, errors.New("unexpected live command")
}

func TestOfflineDoctorSkipsLiveProbes(t *testing.T) {
	site := config.Site{Kea: config.Kea{RequestTimeoutMS: 10}}
	report := Run(context.Background(), site, Options{Live: false, Runner: fakeRunner{}})
	found := false
	for _, check := range report.Checks {
		if check.Name == "live.probes" && check.Status == Warn {
			found = true
		}
	}
	if !found {
		t.Fatal("expected skipped live probe check")
	}
}
