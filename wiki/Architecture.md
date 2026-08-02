# Architecture

## System boundary

`cpctl` is a static Go control-plane CLI. It validates typed configuration, builds deterministic plans, stores durable PostgreSQL state, and will eventually coordinate narrow FreeBSD infrastructure drivers.

```text
site.toml + VM manifest
          |
          v
 strict decode + normalize
          |
          v
 digests + deterministic plan
          |
          v
 PostgreSQL bkcp schema
 declared | allocated | observed | effective
          |
          v
 operation + ordered step journal
          |
          v
 future resumable executor
          |
          +-- image cache and cloud-init
          +-- ZFS and vm-bhyve
          +-- Kea reservations
          +-- PF anchor
```

The current implementation stops before the executor.

## State model

| State | Purpose | Current behavior |
|---|---|---|
| Declared | Normalized requested intent by generation | Persisted as append-only VM specifications |
| Allocated | Durable IP, MAC, storage, subnet, and image assignments | Schema exists; allocation is not implemented |
| Observed | Evidence collected from external systems | Schema exists; collectors are not implemented |
| Effective | Derived reconciliation result and reason | Initialized and exposed through inspection |

Unavailable evidence remains unknown. It is never converted into confirmed absence.

## Determinism

For the same normalized manifest, control-plane ID, generation, action, and ordered step contract, V2 must produce the same:

- specification digest;
- plan digest;
- step input digests;
- idempotency key.

Identical declared intent retains its generation. Changed intent advances the generation exactly once under a transaction-scoped resource lock.

## Persist-before-mutation contract

The internal `PrepareApply` transaction:

1. acquires the resource advisory lock;
2. loads or creates the stable resource UUID;
3. compares the normalized specification digest;
4. retains or advances the generation;
5. appends declared state when it changed;
6. builds the deterministic plan;
7. inserts or reuses the operation by idempotency key;
8. inserts the ordered step journal once;
9. marks effective state as pending;
10. commits.

It executes no external driver.

A future executor may run only persisted steps, must verify each postcondition, and must resume from the first unverified step after interruption.

## Authority boundaries

- PostgreSQL owns V2 intent, allocation records, evidence, effective state, and operation history.
- Kea's hosts database remains authoritative for DHCP reservations.
- ZFS and `vm-bhyve` remain authoritative for storage and VM runtime facts.
- PF changes are restricted to the configured anchor and must not replace site policy.
- Image artifacts require independently verified digests before promotion.

## Privilege boundary

Planning, decoding, and state access should not become an unrestricted root shell. Future privileged execution should use typed operations with explicit inputs and postconditions.

```text
cpctl planning and state
          |
          v
typed privileged executor
          |
 ZFS | PF | services | vm-bhyve
```

Secrets, private keys, credential contents, and complete DSNs must not be persisted in plans, state, or error details.

## Repository layers

```text
cmd/cpctl/                 process entry point
internal/cli/              command parsing and output
internal/config/           typed configuration and normalization
internal/planner/          deterministic plan construction
internal/migrate/          embedded migration runner
internal/state/            state contracts and models
internal/state/postgres/   pgx repository implementation
internal/doctor/           read-only dependency probes
migrations/                immutable SQL migrations
schemas/                   versioned configuration schemas
config/                    examples
wiki/                      operator documentation source
```

## Legacy boundary

V1 is frozen on `legacy/v1-shell`. V2 does not modify legacy `public` schema objects. Future import and adoption must preserve existing names, IP addresses, MAC addresses, storage identities, and Kea reservation identities.