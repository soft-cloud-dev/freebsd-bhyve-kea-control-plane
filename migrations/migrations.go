package migrations

import "embed"

// Files contains immutable PostgreSQL schema migrations.
//
//go:embed *.sql
var Files embed.FS
