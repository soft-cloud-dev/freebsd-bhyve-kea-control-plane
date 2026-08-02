# Architecture

`cpctl` is a static Go control-plane CLI. It validates typed configuration, builds deterministic plans, stores durable PostgreSQL state, and will eventually coordinate narrow FreeBSD infrastructure drivers.

```text
site.toml + VM manifest
          |
          v
 strict decode + normalize
          |
          v
 deterministic plan + digests
          |
          v
 PostgreSQL bkcp schema
 declared | allocated | observed | effective
          |
          v
 operation + ordered-step journal
          |
          v
 future resumable executor
          |
 image | ZFS | cloud-init | Kea | vm-bhyve | PF
```

The current implementation stops before the executor.

## Four-state model

| State | Meaning | Current status |
|---|---|---|
| Declared | Normalized requested intent by generation | Implemented |
| Allocated | Durable IP, MAC, storage, subnet, and image assignments | Schema only |
| Observed | Evidence from authoritative external systems | Schema only |
| Effective | Derived reconciliation result and reason | Implemented foundation |

Unavailable evidence remains unknown. It is never interpreted as confirmed absence.

## Determinism

The same normalized manifest, control-plane ID, generation, action, and ordered-step contract must produce the same:

- specification digest;
- plan digest;
- step input digests;
- idempotency key.

Identical intent retains its generation. Changed intent advances the generation exactly once under a transaction-scoped resource lock.

## Persist before mutation

The internal `PrepareApply` transaction:

1. locks the resource;
2. loads or creates its stable UUID;
3. compares normalized intent;
4. retains or advances the generation;
5. appends changed declared state;
6. builds the deterministic plan;
7. inserts or reuses the operation;
8. stores ordered steps once;
9. marks effective state pending;
10. commits.

It executes no external driver.

A future executor may run only persisted steps, must verify every postcondition, and must resume from the first unverified step after interruption.

## Authority boundaries

- PostgreSQL owns V2 intent, allocations, evidence, effective state, and operation history.
- Kea remains authoritative for DHCP reservations.
- ZFS and `vm-bhyve` remain authoritative for storage and runtime facts.
- PF ownership is limited to the configured anchor.
- Images require independently verified digests before promotion.

Planning and state handling must not become an unrestricted root shell. Future privileged work must use typed driver operations with explicit inputs and verified postconditions.

## PostgreSQL objects

- `bkcp.schema_migrations` — immutable migration history;
- `bkcp.resources` — stable identity and current generation;
- `bkcp.vm_specs` — append-only declared intent;
- `bkcp.vm_allocations` — durable assignments;
- `bkcp.vm_observations` — evidence snapshots;
- `bkcp.vm_effective` — derived state;
- `bkcp.operations` — operation headers;
- `bkcp.operation_steps` — ordered resumable work.

Applied migrations are immutable and checksum-verified. Add a new migration version instead of editing an applied file or checksum row.

## Legacy boundary

V1 is frozen on `legacy/v1-shell`. V2 does not modify legacy `public` objects. Future adoption must preserve guest names, IP addresses, MAC addresses, storage identities, and Kea reservation identities.