package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadSiteRejectsUnknownKeys(t *testing.T) {
	path := writeTemp(t, validSite+"\nunknown = true\n")
	_, err := LoadSite(path)
	if err == nil || !strings.Contains(err.Error(), "unknown keys") {
		t.Fatalf("expected unknown-key error, got %v", err)
	}
}

func TestLoadSiteValidatesReferencesAndRanges(t *testing.T) {
	path := writeTemp(t, validSite)
	site, err := LoadSite(path)
	if err != nil {
		t.Fatalf("LoadSite: %v", err)
	}
	if site.ControlPlaneID != "lab-01" || len(site.Pools) != 1 || len(site.Images) != 1 {
		t.Fatalf("unexpected site: %#v", site)
	}
}

func writeTemp(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "input.toml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

const validSite = `
schema = 1
control_plane_id = "lab-01"

[host]
external_interface = "igb0"
management_interface = "vlan10"
vm_bridge = "bridge0"
vm_dataset = "zroot/vm"
vm_root = "/zroot/vm"

[database]
dsn = "host=/var/run/postgresql dbname=controlplane user=controlplane"

[kea]
api_url = "http://127.0.0.1:8000/"
username_file = "/usr/local/etc/kea/user"
password_file = "/usr/local/etc/kea/password"
hosts_database = "kea_hosts"
request_timeout_ms = 5000

[network]
pf_anchor = "bkcp"
manage_anchor = true

[[pools]]
name = "vm-lan"
subnet = "10.0.20.0/24"
first_host = "10.0.20.10"
last_host = "10.0.20.99"
gateway = "10.0.20.1"
dns_servers = ["10.0.20.1"]
vlan = 20
kea_subnet_id = 1

[[images]]
name = "freebsd-14.3"
url = "https://download.freebsd.org/image.raw.xz"
compressed_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
format = "raw.xz"
loader = "bhyveload"
`
