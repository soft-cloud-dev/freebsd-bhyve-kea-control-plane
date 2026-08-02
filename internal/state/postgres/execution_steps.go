package postgres

import (
	"context"
	"fmt"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

func (r *Repository) ExecutionSteps(ctx context.Context, operationUUID string) ([]state.OperationStep, error) {
	rows, err := r.pool.Query(ctx, `
SELECT operation_uuid::text,sequence,driver,action,input_digest,input_json,
       COALESCE(postcondition_json,''),COALESCE(postcondition_digest,''),
       status,attempts,started_at,completed_at,COALESCE(error_code,''),COALESCE(error_detail,'')
FROM bkcp.operation_steps WHERE operation_uuid=$1 ORDER BY sequence`, operationUUID)
	if err != nil {
		return nil, fmt.Errorf("load executable steps: %w", err)
	}
	defer rows.Close()
	var result []state.OperationStep
	for rows.Next() {
		var step state.OperationStep
		if err := rows.Scan(&step.OperationUUID, &step.Sequence, &step.Driver, &step.Action, &step.InputDigest, &step.InputJSON, &step.PostconditionJSON, &step.PostconditionDigest, &step.Status, &step.Attempts, &step.StartedAt, &step.CompletedAt, &step.ErrorCode, &step.ErrorDetail); err != nil {
			return nil, fmt.Errorf("scan executable step: %w", err)
		}
		result = append(result, step)
	}
	return result, rows.Err()
}
