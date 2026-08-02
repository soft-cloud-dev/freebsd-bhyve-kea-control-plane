package planner

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

const ExecutionInputSchemaVersion = 1

type Allocation struct {
	PoolName             string `json:"pool_name"`
	IPAddress            string `json:"ip_address"`
	MACAddress           string `json:"mac_address"`
	DatasetName          string `json:"dataset_name"`
	ZvolName             string `json:"zvol_name"`
	KeaSubnetID          int    `json:"kea_subnet_id"`
	ImageName            string `json:"image_name"`
	ImageDigest          string `json:"image_digest"`
	AllocationGeneration uint64 `json:"allocation_generation"`
}

type ExecutionHost struct {
	VMBridge  string `json:"vm_bridge"`
	VMDataset string `json:"vm_dataset"`
	VMRoot    string `json:"vm_root"`
}

type ExecutionKea struct {
	APIURL           string `json:"api_url"`
	UsernameFile     string `json:"username_file"`
	PasswordFile     string `json:"password_file"`
	RequestTimeoutMS int    `json:"request_timeout_ms"`
}

type ExecutionNetwork struct {
	PFAnchor     string `json:"pf_anchor"`
	ManageAnchor bool   `json:"manage_anchor"`
}

type ExecutionPool struct {
	Gateway    string   `json:"gateway"`
	DNSServers []string `json:"dns_servers"`
	VLAN       int      `json:"vlan"`
}

type ExecutionImage struct {
	Name             string `json:"name"`
	URL              string `json:"url"`
	CompressedSHA256 string `json:"compressed_sha256"`
	Format           string `json:"format"`
	Loader           string `json:"loader"`
}

type StepInput struct {
	Schema         int                 `json:"schema"`
	Operation      string              `json:"operation"`
	Sequence       int                 `json:"sequence"`
	Driver         string              `json:"driver"`
	Action         string              `json:"action"`
	Resource       string              `json:"resource"`
	Generation     uint64              `json:"generation"`
	Specification  config.NormalizedVM `json:"specification"`
	Allocation     Allocation          `json:"allocation"`
	Host           ExecutionHost       `json:"host"`
	Kea            ExecutionKea        `json:"kea"`
	Network        ExecutionNetwork    `json:"network"`
	Pool           ExecutionPool       `json:"pool"`
	Image          ExecutionImage      `json:"image"`
	DestroyStorage bool                `json:"destroy_storage,omitempty"`
}

type ExecutableStep struct {
	Step      Step      `json:"step"`
	Input     StepInput `json:"input"`
	InputJSON string    `json:"input_json"`
}

type ExecutablePlan struct {
	Plan  Plan             `json:"plan"`
	Steps []ExecutableStep `json:"steps"`
}

func BuildExecutableApply(site config.Site, generation uint64, manifest config.VMManifest, allocation Allocation) (ExecutablePlan, error) {
	return buildExecutable(site, generation, manifest, allocation, "apply", false, [][2]string{
		{"image", "ensure-verified"},
		{"zfs", "ensure-storage"},
		{"cloudinit", "ensure-seed"},
		{"vmbhyve", "ensure-definition"},
		{"vmbhyve", "ensure-config"},
		{"kea", "ensure-reservation"},
		{"pf", "ensure-rules"},
		{"vmbhyve", "ensure-power-state"},
		{"observer", "observe-all"},
	})
}

func BuildExecutableDelete(site config.Site, generation uint64, manifest config.VMManifest, allocation Allocation, destroyStorage bool) (ExecutablePlan, error) {
	if !destroyStorage {
		return ExecutablePlan{}, errors.New("delete requires explicit storage destruction authorization")
	}
	return buildExecutable(site, generation, manifest, allocation, "delete", true, [][2]string{
		{"vmbhyve", "ensure-stopped"},
		{"kea", "ensure-absent"},
		{"pf", "ensure-absent"},
		{"vmbhyve", "ensure-absent"},
		{"cloudinit", "ensure-absent"},
		{"zfs", "ensure-absent"},
		{"observer", "observe-absent"},
	})
}

func buildExecutable(site config.Site, generation uint64, manifest config.VMManifest, allocation Allocation, operation string, destroyStorage bool, actions [][2]string) (ExecutablePlan, error) {
	if generation == 0 {
		return ExecutablePlan{}, errors.New("generation must be positive")
	}
	if err := manifest.Validate(); err != nil {
		return ExecutablePlan{}, err
	}
	pool, image, err := executionReferences(site, manifest)
	if err != nil {
		return ExecutablePlan{}, err
	}
	normalized := manifest.Normalize()
	specDigest, err := manifest.Digest()
	if err != nil {
		return ExecutablePlan{}, fmt.Errorf("digest manifest: %w", err)
	}
	base := StepInput{
		Schema: ExecutionInputSchemaVersion, Operation: operation, Resource: normalized.Name, Generation: generation,
		Specification: normalized, Allocation: allocation,
		Host: ExecutionHost{VMBridge: site.Host.VMBridge, VMDataset: site.Host.VMDataset, VMRoot: site.Host.VMRoot},
		Kea: ExecutionKea{APIURL: site.Kea.APIURL, UsernameFile: site.Kea.UsernameFile, PasswordFile: site.Kea.PasswordFile, RequestTimeoutMS: site.Kea.RequestTimeoutMS},
		Network: ExecutionNetwork{PFAnchor: site.Network.PFAnchor, ManageAnchor: site.Network.ManageAnchor},
		Pool: ExecutionPool{Gateway: pool.Gateway, DNSServers: append([]string(nil), pool.DNSServers...), VLAN: pool.VLAN},
		Image: ExecutionImage{Name: image.Name, URL: image.URL, CompressedSHA256: image.CompressedSHA256, Format: image.Format, Loader: image.Loader},
		DestroyStorage: destroyStorage,
	}
	steps := make([]Step, 0, len(actions))
	executable := make([]ExecutableStep, 0, len(actions))
	for index, pair := range actions {
		input := base
		input.Sequence = index + 1
		input.Driver = pair[0]
		input.Action = pair[1]
		inputJSON, digest, err := DigestStepInput(input)
		if err != nil {
			return ExecutablePlan{}, err
		}
		step := Step{Sequence: input.Sequence, Driver: input.Driver, Action: input.Action, InputDigest: digest}
		steps = append(steps, step)
		executable = append(executable, ExecutableStep{Step: step, Input: input, InputJSON: inputJSON})
	}
	input := digestInput{Schema: PlanSchemaVersion, Action: operation, Resource: normalized.Name, Generation: generation, Specification: normalized, Steps: steps}
	canonical, err := json.Marshal(input)
	if err != nil {
		return ExecutablePlan{}, fmt.Errorf("marshal executable plan: %w", err)
	}
	planHash := sha256.Sum256(canonical)
	planDigest := hex.EncodeToString(planHash[:])
	keyInput := fmt.Sprintf("%s\n%s\n%d\n%s\n%s", site.ControlPlaneID, normalized.Name, generation, operation, planDigest)
	keyHash := sha256.Sum256([]byte(keyInput))
	return ExecutablePlan{Plan: Plan{
		Schema: PlanSchemaVersion, Action: operation, Resource: normalized.Name, Generation: generation,
		Specification: normalized, SpecDigest: specDigest, PlanDigest: planDigest,
		IdempotencyKey: hex.EncodeToString(keyHash[:]), Steps: steps,
	}, Steps: executable}, nil
}

func DigestStepInput(input StepInput) (string, string, error) {
	canonical, err := json.Marshal(input)
	if err != nil {
		return "", "", fmt.Errorf("marshal step input: %w", err)
	}
	digest := sha256.Sum256(canonical)
	return string(canonical), hex.EncodeToString(digest[:]), nil
}

func executionReferences(site config.Site, manifest config.VMManifest) (config.Pool, config.Image, error) {
	var pool config.Pool
	poolFound := false
	for _, candidate := range site.Pools {
		if candidate.Name == manifest.Pool {
			pool = candidate
			poolFound = true
			break
		}
	}
	if !poolFound {
		return config.Pool{}, config.Image{}, fmt.Errorf("manifest references unknown pool %q", manifest.Pool)
	}
	var image config.Image
	imageFound := false
	for _, candidate := range site.Images {
		if candidate.Name == manifest.Image {
			image = candidate
			imageFound = true
			break
		}
	}
	if !imageFound {
		return config.Pool{}, config.Image{}, fmt.Errorf("manifest references unknown image %q", manifest.Image)
	}
	return pool, image, nil
}
