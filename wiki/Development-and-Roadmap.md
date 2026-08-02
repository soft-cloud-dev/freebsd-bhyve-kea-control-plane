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

The suite covers:

- migration repetition and checksums;
- declaration generation semantics;
- concurrent preparation;
- durable and repeatable IP/MAC/storage allocation;
- allocation uniqueness;
- allocation-bound plan identity;
- exact executable step persistence;
- operation and resume-point inspection.

## Execution tests

Portable tests use fake repositories and drivers to cover:

- deterministic allocation helpers;
- allocation-bound step and plan digests;
- resume from the first incomplete step;
- rejection of tampered persisted input;
- execution-lock acquisition and release.

Real FreeBSD behavior is validated through the manually triggered `V2 FreeBSD Execution` workflow on a protected self-hosted runner labelled `self-hosted`, `freebsd`, and `bkcp`.

## Development rules

- Never edit an applied migration; add the next numbered version.
- Commit normalized `go.mod` and `go.sum` changes together.
- Keep portable tests independent of PostgreSQL and FreeBSD.
- Put live PostgreSQL tests behind the `integration` build tag.
- Use the race detector for state and concurrency paths.
- Repeat identical inputs and assert identical allocations, plans, digests, and idempotency keys.
- Persist concrete identities and exact step input before external mutation.
- Verify every driver postcondition through its authoritative system.
- Distinguish unavailable, unknown, present, and absent evidence.
- Never interpret command failure as confirmed absence.
- Never overwrite existing storage whose image identity is unknown or different.
- Never commit credentials, private keys, tokens, or complete DSNs.

Before merge:

```sh
make verify
make integration
```

A lifecycle change additionally requires review of the manual FreeBSD execution workflow and its protected environment.

## CI

- `V2 CI` runs portable verification.
- `V2 PostgreSQL` runs PostgreSQL 16 integration tests with the race detector.
- `V2 FreeBSD Execution` runs an explicitly authorized real-host lifecycle test.
- `Publish GitHub Wiki` synchronizes `wiki/*.md` after the native Wiki is initialized.

## Completed V2 execution milestone

- V2-only `main` with frozen `legacy/v1-shell`;
- strict site and VM configuration;
- deterministic pure and allocation-bound plans;
- checksummed migrations and four-state PostgreSQL schema;
- concurrency-safe declaration generation;
- durable IP, MAC, dataset, zvol, Kea subnet, and image allocation;
- exact persisted step input and verified postcondition evidence;
- typed image, ZFS, cloud-init, Kea, PF, and `vm-bhyve` operations;
- per-resource session execution locks;
- crash-resumable `apply` and destructive `delete`;
- journaled observation-only `reconcile`;
- state, allocation, observation, operation, step, and resume inspection;
- guarded FreeBSD self-hosted execution workflow.

## Next: drift repair policy

Reconcile currently reports drift. Add explicit repair policy rather than silently mutating on every observation:

- safe automatic repair classes;
- changes requiring operator approval;
- destructive or identity-changing changes that remain blocked;
- drift reports with authoritative evidence and proposed steps.

## Next: import and adoption

V1 import must be read-only. Adoption must verify and preserve:

- guest name and UUID mapping;
- IP and MAC;
- dataset and zvol identity;
- image identity;
- Kea reservation;
- current power state.

No existing resource becomes V2-managed until an explicit adoption operation succeeds.

## Next: host bootstrap

VM lifecycle execution assumes a prepared FreeBSD host. A separate host contract may later manage:

- packages and release compatibility;
- interfaces, VLANs, bridges, and `vm-bhyve` switches;
- ZFS parent datasets;
- PostgreSQL and Kea service installation;
- PF parent policy inclusion;
- privilege delegation for the executor;
- observability services.

Host bootstrap must remain distinct from per-VM reconciliation and must preserve site-owned policy.

## Later

- scheduled reconciliation daemon;
- Prometheus metrics, tracing, and structured logs;
- Stork and Unbound integrations;
- explicit image garbage collection;
- signed release artifacts;
- destructive-operation approval workflows;
- broader FreeBSD release and hardware test matrices.

## Executable V2 definition

V2 is operationally executable for new VM resources when the FreeBSD host prerequisites exist. A resource is successful only when its allocation is durable, every external step has verified evidence, observations match intent, and effective state is `converged` or verified `absent`.
