package config

import (
	"strings"
	"testing"
)

func TestVMDigestIsDeterministic(t *testing.T) {
	manifest := validManifest()
	first, err := manifest.Digest()
	if err != nil {
		t.Fatal(err)
	}
	second, err := manifest.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("digest changed: %s != %s", first, second)
	}
}

func TestLoadVMRejectsUnknownKeys(t *testing.T) {
	path := writeTemp(t, validVM+"\nextra = true\n")
	_, err := LoadVM(path)
	if err == nil || !strings.Contains(err.Error(), "unknown keys") {
		t.Fatalf("expected unknown-key error, got %v", err)
	}
}

func validManifest() VMManifest {
	return VMManifest{
		Schema: 1, Name: "freebsd-node-01", Owner: "admin", Image: "freebsd-14.3",
		Profile: "jail-host", Pool: "vm-lan", DesiredPower: "running",
		CPUs: 2, MemoryMB: 4096, DiskGB: 32, SSHPublicKeyFile: "/root/.ssh/id_ed25519.pub",
	}
}

const validVM = `
schema = 1
name = "freebsd-node-01"
owner = "admin"
image = "freebsd-14.3"
profile = "jail-host"
pool = "vm-lan"
desired_power = "running"
cpus = 2
memory_mb = 4096
disk_gb = 32
ssh_public_key_file = "/root/.ssh/id_ed25519.pub"
`
