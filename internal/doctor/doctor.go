package doctor

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

type Status string

const (
	Pass Status = "pass"
	Warn Status = "warn"
	Fail Status = "fail"
)

type Check struct {
	Name     string `json:"name"`
	Status   Status `json:"status"`
	Required bool   `json:"required"`
	Detail   string `json:"detail"`
}

type Report struct {
	Schema int     `json:"schema"`
	Checks []Check `json:"checks"`
}

func (r Report) Healthy() bool {
	for _, check := range r.Checks {
		if check.Required && check.Status == Fail {
			return false
		}
	}
	return true
}

type CommandRunner interface {
	LookPath(file string) (string, error)
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

type HTTPDoer interface {
	Do(request *http.Request) (*http.Response, error)
}

type OSRunner struct{}

func (OSRunner) LookPath(file string) (string, error) { return exec.LookPath(file) }

func (OSRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

type Options struct {
	Live       bool
	Runner     CommandRunner
	HTTPClient HTTPDoer
}

func Run(ctx context.Context, site config.Site, options Options) Report {
	runner := options.Runner
	if runner == nil {
		runner = OSRunner{}
	}
	client := options.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: timeout(site.Kea.RequestTimeoutMS)}
	}
	checks := []Check{{
		Name:     "platform.freebsd",
		Required: true,
		Status:   status(runtime.GOOS == "freebsd"),
		Detail:   fmt.Sprintf("runtime GOOS=%s", runtime.GOOS),
	}}
	commands := []struct {
		Name     string
		Required bool
	}{
		{Name: "vm", Required: true},
		{Name: "zfs", Required: true},
		{Name: "zpool", Required: true},
		{Name: "pfctl", Required: true},
		{Name: "service", Required: true},
		{Name: "makefs", Required: true},
	}
	for _, command := range commands {
		path, err := runner.LookPath(command.Name)
		check := Check{Name: "command." + command.Name, Required: command.Required}
		if err != nil {
			check.Status = Fail
			check.Detail = err.Error()
		} else {
			check.Status = Pass
			check.Detail = path
		}
		checks = append(checks, check)
	}
	if options.Live {
		checks = append(checks, probeZFS(ctx, runner, site))
		checks = append(checks, probePostgres(ctx, site.Database.DSN))
		checks = append(checks, probeKea(ctx, client, site))
	} else {
		checks = append(checks, Check{Name: "live.probes", Required: false, Status: Warn, Detail: "skipped by --offline"})
	}
	sort.SliceStable(checks, func(i, j int) bool { return checks[i].Name < checks[j].Name })
	return Report{Schema: 1, Checks: checks}
}

func probeZFS(ctx context.Context, runner CommandRunner, site config.Site) Check {
	output, err := runner.Run(ctx, "zfs", "list", "-H", "-o", "name", site.Host.VMDataset)
	if err != nil {
		return Check{Name: "live.zfs_dataset", Required: true, Status: Fail, Detail: commandDetail(output, err)}
	}
	return Check{Name: "live.zfs_dataset", Required: true, Status: Pass, Detail: strings.TrimSpace(string(output))}
}

func probeKea(ctx context.Context, client HTTPDoer, site config.Site) Check {
	username, err := config.ReadSecret(site.Kea.UsernameFile)
	if err != nil {
		return Check{Name: "live.kea", Required: true, Status: Fail, Detail: "read username: " + err.Error()}
	}
	password, err := config.ReadSecret(site.Kea.PasswordFile)
	if err != nil {
		return Check{Name: "live.kea", Required: true, Status: Fail, Detail: "read password: " + err.Error()}
	}
	payload, _ := json.Marshal(map[string]any{"command": "list-commands", "service": []string{"dhcp4"}})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, site.Kea.APIURL, bytes.NewReader(payload))
	if err != nil {
		return Check{Name: "live.kea", Required: true, Status: Fail, Detail: err.Error()}
	}
	request.Header.Set("Content-Type", "application/json")
	request.SetBasicAuth(username, password)
	response, err := client.Do(request)
	if err != nil {
		return Check{Name: "live.kea", Required: true, Status: Fail, Detail: err.Error()}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Check{Name: "live.kea", Required: true, Status: Fail, Detail: response.Status}
	}
	return Check{Name: "live.kea", Required: true, Status: Pass, Detail: response.Status}
}

func status(ok bool) Status {
	if ok {
		return Pass
	}
	return Fail
}

func timeout(milliseconds int) time.Duration {
	if milliseconds <= 0 {
		return 5 * time.Second
	}
	return time.Duration(milliseconds) * time.Millisecond
}

func commandDetail(output []byte, err error) string {
	detail := strings.TrimSpace(string(output))
	if detail == "" {
		return err.Error()
	}
	return fmt.Sprintf("%v: %s", err, detail)
}
