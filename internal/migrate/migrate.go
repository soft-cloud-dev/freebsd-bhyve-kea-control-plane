package migrate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/migrations"
)

const migrationLockID int64 = 0x424b43504d494752

var ErrChecksumMismatch = errors.New("migration checksum mismatch")

type Migration struct {
	Version  int64  `json:"version"`
	Name     string `json:"name"`
	Checksum string `json:"checksum"`
	SQL      string `json:"-"`
}

type Plan struct {
	CurrentVersion int64       `json:"current_version"`
	Pending        []Migration `json:"pending"`
}

type Result struct {
	Applied []Migration `json:"applied"`
	Plan    Plan        `json:"plan"`
}

type Runner struct {
	migrations []Migration
}

func New() (*Runner, error) {
	entries, err := fs.ReadDir(migrations.Files, ".")
	if err != nil {
		return nil, fmt.Errorf("read embedded migrations: %w", err)
	}
	var items []Migration
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		parts := strings.SplitN(strings.TrimSuffix(entry.Name(), ".sql"), "_", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid migration filename %q", entry.Name())
		}
		version, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil || version <= 0 {
			return nil, fmt.Errorf("invalid migration version in %q", entry.Name())
		}
		content, err := fs.ReadFile(migrations.Files, entry.Name())
		if err != nil {
			return nil, fmt.Errorf("read migration %s: %w", entry.Name(), err)
		}
		digest := sha256.Sum256(content)
		items = append(items, Migration{Version: version, Name: parts[1], Checksum: hex.EncodeToString(digest[:]), SQL: string(content)})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Version < items[j].Version })
	for i := 1; i < len(items); i++ {
		if items[i-1].Version == items[i].Version {
			return nil, fmt.Errorf("duplicate migration version %d", items[i].Version)
		}
	}
	return &Runner{migrations: items}, nil
}

func Connect(ctx context.Context, dsn string) (*pgx.Conn, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect PostgreSQL: %w", err)
	}
	return conn, nil
}

func (r *Runner) Plan(ctx context.Context, conn *pgx.Conn) (Plan, error) {
	var exists bool
	if err := conn.QueryRow(ctx, `SELECT to_regclass('bkcp.schema_migrations') IS NOT NULL`).Scan(&exists); err != nil {
		return Plan{}, fmt.Errorf("inspect migration table: %w", err)
	}
	applied := map[int64]string{}
	var current int64
	if exists {
		rows, err := conn.Query(ctx, `SELECT version, checksum FROM bkcp.schema_migrations ORDER BY version`)
		if err != nil {
			return Plan{}, fmt.Errorf("read applied migrations: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var version int64
			var checksum string
			if err := rows.Scan(&version, &checksum); err != nil {
				return Plan{}, fmt.Errorf("scan applied migration: %w", err)
			}
			applied[version] = checksum
			if version > current {
				current = version
			}
		}
		if err := rows.Err(); err != nil {
			return Plan{}, fmt.Errorf("read applied migrations: %w", err)
		}
	}
	var pending []Migration
	known := map[int64]struct{}{}
	for _, migration := range r.migrations {
		known[migration.Version] = struct{}{}
		if checksum, ok := applied[migration.Version]; ok {
			if checksum != migration.Checksum {
				return Plan{}, fmt.Errorf("%w: version %d stored=%s embedded=%s", ErrChecksumMismatch, migration.Version, checksum, migration.Checksum)
			}
			continue
		}
		pending = append(pending, migration)
	}
	for version := range applied {
		if _, ok := known[version]; !ok {
			return Plan{}, fmt.Errorf("database contains unknown migration version %d", version)
		}
	}
	return Plan{CurrentVersion: current, Pending: pending}, nil
}

func (r *Runner) Run(ctx context.Context, conn *pgx.Conn) (Result, error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return Result{}, fmt.Errorf("begin migration transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, migrationLockID); err != nil {
		return Result{}, fmt.Errorf("acquire migration lock: %w", err)
	}
	if _, err := tx.Exec(ctx, `
CREATE SCHEMA IF NOT EXISTS bkcp;
CREATE TABLE IF NOT EXISTS bkcp.schema_migrations (
    version BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    checksum CHAR(64) NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
)`); err != nil {
		return Result{}, fmt.Errorf("bootstrap migration table: %w", err)
	}
	plan, err := r.planTx(ctx, tx)
	if err != nil {
		return Result{}, err
	}
	for _, migration := range plan.Pending {
		if _, err := tx.Exec(ctx, migration.SQL); err != nil {
			return Result{}, fmt.Errorf("apply migration %d_%s: %w", migration.Version, migration.Name, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO bkcp.schema_migrations(version, name, checksum) VALUES ($1, $2, $3)`, migration.Version, migration.Name, migration.Checksum); err != nil {
			return Result{}, fmt.Errorf("record migration %d: %w", migration.Version, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Result{}, fmt.Errorf("commit migrations: %w", err)
	}
	return Result{Applied: plan.Pending, Plan: plan}, nil
}

func (r *Runner) planTx(ctx context.Context, tx pgx.Tx) (Plan, error) {
	rows, err := tx.Query(ctx, `SELECT version, checksum FROM bkcp.schema_migrations ORDER BY version`)
	if err != nil {
		return Plan{}, fmt.Errorf("read applied migrations: %w", err)
	}
	defer rows.Close()
	applied := map[int64]string{}
	var current int64
	for rows.Next() {
		var version int64
		var checksum string
		if err := rows.Scan(&version, &checksum); err != nil {
			return Plan{}, err
		}
		applied[version] = checksum
		if version > current {
			current = version
		}
	}
	if err := rows.Err(); err != nil {
		return Plan{}, err
	}
	var pending []Migration
	for _, migration := range r.migrations {
		if checksum, ok := applied[migration.Version]; ok {
			if checksum != migration.Checksum {
				return Plan{}, fmt.Errorf("%w: version %d", ErrChecksumMismatch, migration.Version)
			}
			continue
		}
		pending = append(pending, migration)
	}
	return Plan{CurrentVersion: current, Pending: pending}, nil
}
