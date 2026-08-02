package state

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/config"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
)

var ErrNotFound = errors.New("resource not found")
var ErrBlocked = errors.New("operation blocked")
var ErrDrift = errors.New("resource drift detected")

type ResourceSummary struct {
	UUID            string `json:"uuid"`
	Name            string `json:"name"`
	Managed         bool   `json:"managed"`
	Generation      uint64 `json:"generation"`
	EffectiveState  string `json:"effective_state"`
	OperationStatus string `json:"operation_status,omitempty"`
}

type DeclaredVM struct {
	ResourceUUID  string              `json:"resource_uuid"`
	Generation    uint64              `json:"generation"`
	Specification config.NormalizedVM `json:"specification"`
	SpecDigest    string              `json:"spec_digest"`
	SourcePath    string              `json:"source_path,omitempty"`
	DeclaredAt    time.Time           `json:"declared_at"`
}

type Allocation struct {
	PoolName             string     `json:"pool_name"`
	IPAddress            string     `json:"ip_address,omitempty"`
	MACAddress           string     `json:"mac_address,omitempty"`
	DatasetName          string     `json:"dataset_name,omitempty"`
	ZvolName             string     `json:"zvol_name,omitempty"`
	KeaSubnetID          int        `json:"kea_subnet_id,omitempty"`
	ImageName            string     `json:"image_name"`
	ImageDigest          string     `json:"image_digest,omitempty"`
	AllocationGeneration uint64     `json:"allocation_generation"`
	AllocatedAt          time.Time  `json:"allocated_at"`
	ReleasedAt           *time.Time `json:"released_at,omitempty"`
}

type Observation struct {
	UUID            string         `json:"uuid,omitempty"`
	ResourceUUID    string         `json:"resource_uuid"`
	CollectedAt     time.Time      `json:"collected_at,omitempty"`
	ObserverVersion string         `json:"observer_version"`
	VMState         string         `json:"vm_state"`
	StorageState    string         `json:"storage_state"`
	KeaState        string         `json:"kea_state"`
	SeedState       string         `json:"seed_state"`
	PowerState      string         `json:"power_state"`
	Observed        map[string]any `json:"observed"`
	ErrorCode       string         `json:"error_code,omitempty"`
	ErrorDetail     string         `json:"error_detail,omitempty"`
	PlanDigest      string         `json:"plan_digest,omitempty"`
}

type Effective struct {
	State             string    `json:"state"`
	ReasonCode        string    `json:"reason_code,omitempty"`
	ReasonDetail      string    `json:"reason_detail,omitempty"`
	CurrentPlanDigest string    `json:"current_plan_digest,omitempty"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type Operation struct {
	UUID           string     `json:"uuid"`
	ResourceUUID   string     `json:"resource_uuid"`
	Generation     uint64     `json:"generation"`
	Action         string     `json:"action"`
	SpecDigest     string     `json:"spec_digest"`
	PlanDigest     string     `json:"plan_digest"`
	IdempotencyKey string     `json:"idempotency_key"`
	Status         string     `json:"status"`
	Attempts       int        `json:"attempts"`
	CreatedAt      time.Time  `json:"created_at"`
	StartedAt      *time.Time `json:"started_at,omitempty"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
	ErrorCode      string     `json:"error_code,omitempty"`
	ErrorDetail    string     `json:"error_detail,omitempty"`
}

type OperationStep struct {
	OperationUUID      string     `json:"operation_uuid"`
	Sequence           int        `json:"sequence"`
	Driver             string     `json:"driver"`
	Action             string     `json:"action"`
	InputDigest        string     `json:"input_digest"`
	InputJSON          string     `json:"input_json,omitempty"`
	PostconditionJSON  string     `json:"postcondition_json,omitempty"`
	PostconditionDigest string    `json:"postcondition_digest,omitempty"`
	Status             string     `json:"status"`
	Attempts           int        `json:"attempts"`
	StartedAt          *time.Time `json:"started_at,omitempty"`
	CompletedAt        *time.Time `json:"completed_at,omitempty"`
	ErrorCode          string     `json:"error_code,omitempty"`
	ErrorDetail        string     `json:"error_detail,omitempty"`
}

type Inspection struct {
	Resource    ResourceSummary `json:"resource"`
	Declared    *DeclaredVM     `json:"declared,omitempty"`
	Allocation  *Allocation     `json:"allocation,omitempty"`
	Observation *Observation    `json:"observation,omitempty"`
	Effective   *Effective      `json:"effective,omitempty"`
	Operation   *Operation      `json:"operation,omitempty"`
	Steps       []OperationStep `json:"steps,omitempty"`
	ResumeStep  *OperationStep  `json:"resume_step,omitempty"`
}

type PreparedApply struct {
	Resource  ResourceSummary `json:"resource"`
	Plan      planner.Plan    `json:"plan"`
	Operation Operation       `json:"operation"`
	Created   bool            `json:"created"`
}

func EncodeSpecification(spec config.NormalizedVM) ([]byte, error) { return json.Marshal(spec) }
