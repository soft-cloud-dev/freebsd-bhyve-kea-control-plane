# Development and Testing

## Local verification

```sh
make verify
make build
```

`make verify` checks formatting, runs `go vet`, executes race-enabled unit tests, builds `bin/cpctl`, and validates checked-in configuration examples.

## PostgreSQL integration tests

```sh
export BKCP_TEST_DATABASE_URL='postgres://bkcp:bkcp@127.0.0.1:5432/bkcp?sslmode=disable'
make integration
```

Equivalent command:

```sh
go test -race -tags=integration ./internal/state/postgres/...
```

The integration suite covers migration repetition, generation semantics, operation and step persistence, resume-point inspection, rollback, and convergence of concurrent identical preparations.

## Dependency reproducibility

```sh
go mod tidy
git diff --exit-code -- go.mod go.sum
```

Commit both files for dependency changes.

## Migration rules

Applied migrations are immutable.

1. Never edit an applied migration.
2. Add the next numbered migration.
3. Test both empty and previously migrated databases.
4. Test concurrent migration calls.
5. Confirm that legacy `public` objects remain untouched.

## State and planning rules

- Repeat identical inputs and assert identical digests and plans.
- Assert changed generations or digests for changed normalized intent.
- Keep portable tests independent of PostgreSQL and FreeBSD.
- Put live PostgreSQL tests behind the `integration` tag.
- Use the race detector on state and concurrency paths.
- Distinguish unavailable, unknown, present, and absent evidence.
- Test rollback so no partial resource, specification, operation, or step graph remains.

## Security rules

- Never commit or log passwords, private keys, tokens, credential contents, or complete DSNs.
- Persist only typed, bounded operation inputs and errors.
- Do not introduce arbitrary root shell execution.
- Keep future privileged drivers narrow and postcondition-driven.
- Do not load PF outside the configured anchor.
- Do not promote an image before digest verification.
- Do not mark journal steps successful without verifying authoritative external state.

## Pull-request checklist

Before merge:

```sh
make verify
make integration
```

Review for:

- accidental V1 restoration;
- migration edits instead of new versions;
- nondeterministic map, query, or step ordering;
- inference of absence from unavailable evidence;
- external mutation before journal persistence;
- credentials in code, configuration, logs, fixtures, or errors;
- unrelated driver work mixed into the iteration.

## CI

- `V2 CI` runs portable verification.
- `V2 PostgreSQL` runs PostgreSQL 16 integration tests with the race detector.
- `Publish GitHub Wiki` synchronizes `wiki/*.md` to the native Wiki after it is initialized.

Future FreeBSD execution tests must remain separate because Linux CI cannot validate `vm-bhyve`, ZFS, PF, or FreeBSD service semantics.