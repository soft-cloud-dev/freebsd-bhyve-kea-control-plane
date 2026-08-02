package postgres

import (
	"context"
	"fmt"
	"sync"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

func (r *Repository) LockExecution(ctx context.Context, resourceUUID string) (func(), error) {
	connection, err := r.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire execution lock connection: %w", err)
	}
	var locked bool
	lockKey := "bkcp:execute:" + resourceUUID
	if err := connection.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtextextended($1, 0))`, lockKey).Scan(&locked); err != nil {
		connection.Release()
		return nil, fmt.Errorf("acquire execution advisory lock: %w", err)
	}
	if !locked {
		connection.Release()
		return nil, fmt.Errorf("%w: another executor is active for resource %s", state.ErrBlocked, resourceUUID)
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			_, _ = connection.Exec(context.Background(), `SELECT pg_advisory_unlock(hashtextextended($1, 0))`, lockKey)
			connection.Release()
		})
	}, nil
}
