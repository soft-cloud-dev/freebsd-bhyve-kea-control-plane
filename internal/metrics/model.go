package metrics

import (
	"context"
	"time"
)

type Source interface {
	Snapshot(context.Context) (Snapshot, error)
	Ping(context.Context) error
}

type Snapshot struct {
	CollectedAt      time.Time
	Resources        []Resource
	OperationCounts  []OperationCount
	StepCounts       []StepCount
	AllocationCounts []AllocationCount
}

type Resource struct {
	Name                           string
	Managed                        bool
	Generation                     uint64
	EffectiveState                 string
	DesiredPower                   string
	Pool                           string
	Image                          string
	LastSuccessfulReconciliationAt *time.Time
	ObservationCollectedAt         *time.Time
	ObservationStates              map[string]string
	LatestOperationAction          string
	LatestOperationStatus          string
	LatestOperationAttempts        int
}

type OperationCount struct {
	Action string
	Status string
	Count  int64
}

type StepCount struct {
	Driver string
	Action string
	Status string
	Count  int64
}

type AllocationCount struct {
	Pool  string
	State string
	Count int64
}
