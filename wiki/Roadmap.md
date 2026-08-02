# Roadmap

V2 advances only when each layer has deterministic inputs, durable state, idempotent behavior, and verified postconditions.

## Completed

- V2-only `main` and frozen `legacy/v1-shell`.
- Strict site and VM configuration.
- Deterministic normalization, plans, step digests, and idempotency keys.
- FreeBSD dependency probes.
- Embedded checksummed PostgreSQL migrations.
- Dedicated `bkcp` four-state schema.
- Concurrency-safe generation assignment and operation preparation.
- Read-only `status` and `inspect`.
- PostgreSQL 16 race-enabled CI.

## 1. Durable allocations

Implement concurrency-safe allocation for:

- IP addresses;
- locally administered MAC addresses;
- dataset and zvol names;
- image digest bindings.

Assignments must survive retries, restarts, and repeated planning.

## 2. Read-only observations

Collect typed evidence from:

- `vm-bhyve`;
- ZFS;
- Kea;
- cloud-init seed artifacts;
- PF anchor state.

Unavailable, unknown, present, and absent must remain distinct.

## 3. Typed drivers

Add independently retryable drivers for:

- image cache and verification;
- ZFS storage;
- VM configuration and lifecycle;
- cloud-init seed generation;
- Kea reservations;
- PF anchor rules.

Every action requires explicit preconditions and postconditions.

## 4. Resumable `apply`

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

A crash resumes from the first unverified postcondition.

## 5. Delete, import, and adoption

Deletion must be deterministic and explicit about destructive storage policy.

V1 import is read-only. Adoption must preserve guest name, IP, MAC, storage identity, and Kea reservation identity. Nothing becomes V2-managed implicitly.

## Later

- scheduled reconciliation and drift repair;
- Prometheus metrics and structured logs;
- Stork and Unbound integration;
- FreeBSD package and service bootstrap;
- signed release artifacts;
- dedicated FreeBSD bare-metal CI.

## Executable V2 definition

V2 is operationally executable only when allocations are durable, all drivers are idempotent, every step verifies a postcondition, interrupted work resumes safely, unknown evidence never becomes absence, and apply/delete pass PostgreSQL and FreeBSD integration tests.