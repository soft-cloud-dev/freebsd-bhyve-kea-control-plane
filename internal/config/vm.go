package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/tomlx"
)

const VMSchemaVersion = 1

var vmNamePattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

type VMManifest struct {
	Schema           int    `json:"schema"`
	Name             string `json:"name"`
	Owner            string `json:"owner"`
	Image            string `json:"image"`
	Profile          string `json:"profile"`
	Pool             string `json:"pool"`
	DesiredPower     string `json:"desired_power"`
	CPUs             int    `json:"cpus"`
	MemoryMB         int    `json:"memory_mb"`
	DiskGB           int    `json:"disk_gb"`
	SSHPublicKeyFile string `json:"ssh_public_key_file,omitempty"`
}

type NormalizedVM struct {
	Schema           int    `json:"schema"`
	Name             string `json:"name"`
	Owner            string `json:"owner"`
	Image            string `json:"image"`
	Profile          string `json:"profile"`
	Pool             string `json:"pool"`
	DesiredPower     string `json:"desired_power"`
	CPUs             int    `json:"cpus"`
	MemoryMB         int    `json:"memory_mb"`
	DiskGB           int    `json:"disk_gb"`
	SSHPublicKeyFile string `json:"ssh_public_key_file,omitempty"`
}

func LoadVM(path string) (VMManifest, error) {
	doc, err := tomlx.ParseFile(path)
	if err != nil {
		return VMManifest{}, fmt.Errorf("decode VM manifest: %w", err)
	}
	if err := rejectUnknown(doc, "schema", "name", "owner", "image", "profile", "pool", "desired_power", "cpus", "memory_mb", "disk_gb", "ssh_public_key_file"); err != nil {
		return VMManifest{}, fmt.Errorf("decode VM manifest: %w", err)
	}
	var manifest VMManifest
	if manifest.Schema, err = requiredInt(doc, "schema"); err != nil {
		return VMManifest{}, err
	}
	if manifest.Name, err = requiredString(doc, "name"); err != nil {
		return VMManifest{}, err
	}
	if manifest.Owner, err = requiredString(doc, "owner"); err != nil {
		return VMManifest{}, err
	}
	if manifest.Image, err = requiredString(doc, "image"); err != nil {
		return VMManifest{}, err
	}
	if manifest.Profile, err = requiredString(doc, "profile"); err != nil {
		return VMManifest{}, err
	}
	if manifest.Pool, err = requiredString(doc, "pool"); err != nil {
		return VMManifest{}, err
	}
	if manifest.DesiredPower, err = requiredString(doc, "desired_power"); err != nil {
		return VMManifest{}, err
	}
	if manifest.CPUs, err = requiredInt(doc, "cpus"); err != nil {
		return VMManifest{}, err
	}
	if manifest.MemoryMB, err = requiredInt(doc, "memory_mb"); err != nil {
		return VMManifest{}, err
	}
	if manifest.DiskGB, err = requiredInt(doc, "disk_gb"); err != nil {
		return VMManifest{}, err
	}
	if manifest.SSHPublicKeyFile, err = optionalString(doc, "ssh_public_key_file"); err != nil {
		return VMManifest{}, err
	}
	if err := manifest.Validate(); err != nil {
		return VMManifest{}, err
	}
	return manifest, nil
}

func (m VMManifest) Validate() error {
	var problems []error
	if m.Schema != VMSchemaVersion {
		problems = append(problems, fmt.Errorf("schema must be %d", VMSchemaVersion))
	}
	if !vmNamePattern.MatchString(m.Name) {
		problems = append(problems, errors.New("name must be a lowercase DNS label"))
	}
	if strings.TrimSpace(m.Owner) == "" {
		problems = append(problems, errors.New("owner is required"))
	}
	if strings.TrimSpace(m.Image) == "" {
		problems = append(problems, errors.New("image is required"))
	}
	if strings.TrimSpace(m.Profile) == "" {
		problems = append(problems, errors.New("profile is required"))
	}
	if strings.TrimSpace(m.Pool) == "" {
		problems = append(problems, errors.New("pool is required"))
	}
	if m.DesiredPower != "running" && m.DesiredPower != "stopped" {
		problems = append(problems, errors.New("desired_power must be running or stopped"))
	}
	if m.CPUs < 1 || m.CPUs > 64 {
		problems = append(problems, errors.New("cpus must be between 1 and 64"))
	}
	if m.MemoryMB < 128 {
		problems = append(problems, errors.New("memory_mb must be at least 128"))
	}
	if m.DiskGB < 1 {
		problems = append(problems, errors.New("disk_gb must be positive"))
	}
	if m.SSHPublicKeyFile != "" && !filepath.IsAbs(m.SSHPublicKeyFile) {
		problems = append(problems, errors.New("ssh_public_key_file must be absolute when set"))
	}
	return errors.Join(problems...)
}

func (m VMManifest) Normalize() NormalizedVM {
	keyPath := ""
	if m.SSHPublicKeyFile != "" {
		keyPath = filepath.Clean(m.SSHPublicKeyFile)
	}
	return NormalizedVM{Schema: VMSchemaVersion, Name: strings.TrimSpace(m.Name), Owner: strings.TrimSpace(m.Owner), Image: strings.TrimSpace(m.Image), Profile: strings.TrimSpace(m.Profile), Pool: strings.TrimSpace(m.Pool), DesiredPower: strings.TrimSpace(m.DesiredPower), CPUs: m.CPUs, MemoryMB: m.MemoryMB, DiskGB: m.DiskGB, SSHPublicKeyFile: keyPath}
}

func (m VMManifest) CanonicalJSON() ([]byte, error) { return json.Marshal(m.Normalize()) }
func (m VMManifest) Digest() (string, error) {
	canonical, err := m.CanonicalJSON()
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return hex.EncodeToString(digest[:]), nil
}
