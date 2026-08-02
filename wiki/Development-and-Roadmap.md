# Development and Roadmap

## Local verification

```sh
make verify
make build
```

`make verify` checks formatting, runs `go vet`, executes race-enabled unit tests, builds `bin/cpctl`, and validates checked-in configuration examples.

## PostgreSQL integration

```sh
export BKCP_TEST_DATABASE_URL='postgres://bkcp:bkcp@127.0.0.1:5432/bkcp?sslmode=disable'
make integration
```

Equivalent command:

```sh
go test -race -tags=integration ./internal/state/postgres/...
```

The suite covers migration repetition, generation semantics, operation and step persistence, resume-point inspection, rollback, and concurrent identical preparation.

## Development rules

- Commit normalized `go.mod` and `go.sum` changes together.
- Never edit an applied migration; add the next numbered version.
- Keep portable tests independent of PostgreSQL and FreeBSD.
- Put live PostgreSQL tests behind the `integration` build tag.
- Use the race detector for state and concurrency paths.
- Repeat identical inputs and assert identical plans and digests.
- Distinguish unavailable, unknown, present, and absent evidence.
- Test rollback so no partial state or operation graph remains.
- Persist operations before any future external mutation.
- Never commit credentials, private keys, tokens, or complete DSNs.

Before merge:

```sh
make verify
make integration
```

## CI

- `V2 CI` runs portable verification.
- `V2 PostgreSQL` runs PostgreSQL 16 integration tests with the race detector.
- `Publish GitHub Wiki` synchronizes `wiki/*.md` after the native Wiki is initialized.

FreeBSD execution tests must remain separate because Linux CI cannot validate `vm-bhyve`, ZFS, PF, or FreeBSD service behavior.

## Delivery sequence

### Completed foundation

- V2-only `main` with frozen `legacy/v1-shell`;
- strict site and VM configuration;
- deterministic plans, step digests, and idempotency keys;
- dependency probes;
- embedded checksummed migrations;
- dedicated `bkcp` four-state schema;
- concurrency-safe generation and operation preparation;
- read-only state inspection;
- PostgreSQL 16 race-enabled CI.

### 1. Durable allocations

Add concurrency-safe IP, MAC, dataset, zvol, and image-digest assignments that survive retries and restarts.

### 2. Read-only observations

Collect typed evidence from `vm-bhyve`, ZFS, Kea, cloud-init seed artifacts, and PF. Preserve unavailable, unknown, present, and absent as distinct values.

### 3. Typed drivers

Implement independently retryable drivers for image verification, ZFS, VM configuration, cloud-init, Kea reservations, and PF anchor rules. Every action requires explicit preconditions and postconditions.

### 4. Resumable `apply`

```text
prepare or reuse operation
collect observations
execute first incomplete step
verify postcondition
persist success
repeat
collect final observations
derive effective state
```

A crash must resume from the first unverified postcondition.

### 5. Delete, import, and adoption

Deletion must define destructive storage behavior explicitly. V1 import is read-only. Adoption must preserve guest name, IP, MAC, storage identity, and Kea reservation identity.

### Later

- scheduled reconciliation and drift repair;
- Prometheus metrics and structured logs;
- Stork and Unbound integration;
- FreeBSD package and service bootstrap;
- signed release artifacts;
- dedicated FreeBSD bare-metal CI.

## Executable V2 definition

V2 becomes operationally executable only when allocations are durable, every driver is idempotent, every step verifies a postcondition, interrupted work resumes safely, unknown evidence never becomes absence, and apply/delete pass PostgreSQL and FreeBSD integration tests.