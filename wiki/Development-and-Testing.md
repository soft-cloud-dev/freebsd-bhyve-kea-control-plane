# Development and Testing

## Local workflow

```sh
make verify
make build
```

`make verify` runs the portable gate:

- formatting verification;
- `go vet ./...`;
- race-enabled unit tests;
- binary build;
- checked-in configuration example validation.

The generated binary is `bin/cpctl`.

## PostgreSQL integration tests

Set a PostgreSQL 16 test DSN:

```sh
export BKCP_TEST_DATABASE_URL='postgres://bkcp:bkcp@127.0.0.1:5432/bkcp?sslmode=disable'
make integration
```

Equivalent direct command:

```sh
go test -race -tags=integration ./internal/state/postgres/...
```

The integration suite covers:

- applying migrations to an empty database;
- migration repetition;
- generation retention for identical normalized intent;
- generation advancement for changed intent;
- operation and ordered-step persistence;
- resume-point inspection;
- convergence of 32 concurrent identical `PrepareApply` calls.

## Module reproducibility

CI verifies that the committed module graph is already normalized:

```sh
go mod tidy
git diff --exit-code -- go.mod go.sum
```

Dependency changes must commit both `go.mod` and `go.sum` updates.

## Test design rules

- Keep portable tests independent of Docker and PostgreSQL.
- Put live PostgreSQL tests behind the `integration` build tag.
- Use the race detector for state and concurrency paths.
- Test deterministic output by repeating identical inputs.
- Test changed inputs by asserting changed digests or generations.
- Test unknown and unavailable observations separately from absence.
- Test rollback paths so no partial resource/specification/operation graph remains.

## Migration development

Applied migrations are immutable.

To change the schema:

1. leave existing migration files byte-for-byte unchanged;
2. create the next monotonically numbered SQL migration;
3. update embedded migration discovery if required;
4. test an empty database and an already migrated database;
5. test concurrent migration calls;
6. verify that V1 `public` objects are untouched.

## Pull-request boundary

Keep each iteration reviewable. Do not mix unrelated infrastructure drivers into state or documentation changes.

Before merging:

```sh
make verify
make integration
```

Review the diff for:

- accidental V1 restoration;
- secrets or credential contents;
- migration edits instead of new migration versions;
- nondeterministic map or query ordering;
- inference of absence from unavailable evidence;
- external mutation before journal persistence.

## CI workflows

- `V2 CI` runs the portable verification gate.
- `V2 PostgreSQL` starts PostgreSQL 16 and runs the race-enabled integration suite.

A future FreeBSD execution workflow should remain separate because Linux CI cannot validate `vm-bhyve`, ZFS, PF, or FreeBSD service semantics.