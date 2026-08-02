package planner

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
)

const PlanSchemaVersion = 1

type Step struct {
	Sequence int    `json:"sequence"`
	Driver   string `json:"driver"`
	Action   string `json:"action"`
}

type Plan struct {
	Schema         int                 `json:"schema"`
	Action         string              `json:"action"`
	Resource       string              `json:"resource"`
	Generation     uint64              `json:"generation"`
	Specification  config.NormalizedVM `json:"specification"`
	SpecDigest     string              `json:"spec_digest"`
	PlanDigest     string              `json:"plan_digest"`
	IdempotencyKey string              `json:"idempotency_key"`
	Steps          []Step              `json:"steps"`
}

type digestInput struct {
	Schema        int                 `json:"schema"`
	Action        string              `json:"action"`
	Resource      string              `json:"resource"`
	Generation    uint64              `json:"generation"`
	Specification config.NormalizedVM `json:"specification"`
	Steps         []Step              `json:"steps"`
}

func BuildApply(controlPlaneID string, generation uint64, manifest config.VMManifest) (Plan, error) {
	if controlPlaneID == "" {
		return Plan{}, fmt.Errorf("control plane ID is required")
	}
	if generation == 0 {
		return Plan{}, fmt.Errorf("generation must be positive")
	}
	if err := manifest.Validate(); err != nil {
		return Plan{}, err
	}
	normalized := manifest.Normalize()
	specDigest, err := manifest.Digest()
	if err != nil {
		return Plan{}, fmt.Errorf("digest manifest: %w", err)
	}
	steps := []Step{
		{Sequence: 1, Driver: "image", Action: "ensure-verified"},
		{Sequence: 2, Driver: "vmbhyve", Action: "ensure-definition"},
		{Sequence: 3, Driver: "zfs", Action: "ensure-storage"},
		{Sequence: 4, Driver: "vmbhyve", Action: "ensure-config"},
		{Sequence: 5, Driver: "cloudinit", Action: "ensure-seed"},
		{Sequence: 6, Driver: "kea", Action: "ensure-reservation"},
		{Sequence: 7, Driver: "vmbhyve", Action: "ensure-power-state"},
		{Sequence: 8, Driver: "observer", Action: "observe-all"},
	}
	input := digestInput{
		Schema:        PlanSchemaVersion,
		Action:        "apply",
		Resource:      normalized.Name,
		Generation:    generation,
		Specification: normalized,
		Steps:         steps,
	}
	canonical, err := json.Marshal(input)
	if err != nil {
		return Plan{}, fmt.Errorf("marshal plan input: %w", err)
	}
	planHash := sha256.Sum256(canonical)
	planDigest := hex.EncodeToString(planHash[:])
	keyInput := fmt.Sprintf("%s\n%s\n%d\napply\n%s", controlPlaneID, normalized.Name, generation, planDigest)
	keyHash := sha256.Sum256([]byte(keyInput))
	return Plan{
		Schema:         PlanSchemaVersion,
		Action:         "apply",
		Resource:       normalized.Name,
		Generation:     generation,
		Specification:  normalized,
		SpecDigest:     specDigest,
		PlanDigest:     planDigest,
		IdempotencyKey: hex.EncodeToString(keyHash[:]),
		Steps:          steps,
	}, nil
}
