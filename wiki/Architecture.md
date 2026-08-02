# Architecture

## System boundary

The control plane is a static Go binary, `cpctl`, that coordinates typed configuration, deterministic planning, PostgreSQL state, and future FreeBSD infrastructure drivers.

```text
site.toml + VM manifests
          |
          v
    strict decoding
          |
          v
 normalization + digests
          |
          v
 deterministic planner
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
          +-- ZFS / vm-bhyve
          +-- image and cloud-init
          +-- Kea reservations
          +-- PF anchor
```

## Core principles

### Determinism

Identical normalized input, control-plane ID, generation, action, and ordered step contract must produce identical:

- specification digest;
- plan digest;
- per-step input digests;
- idempotency key.

This makes plans reproducible and permits safe operation reuse.

### Four-state separation

The model keeps four state classes independent:

- **Declared** — normalized requested intent by generation.
- **Allocated** — durable assigned identities such as IP, MAC, dataset, and image digest.
- **Observed** — evidence collected from external systems, including unavailable and unknown values.
- **Effective** — derived reconciliation state and reason.

Unknown evidence is not converted into confirmed absence.

### Persist before mutation

A future executor must persist the exact operation and its ordered steps before changing any external system. Each successful step records its postcondition so execution can resume after interruption.

### Narrow infrastructure ownership

- PostgreSQL owns control-plane state and journals.
- Kea's hosts database remains authoritative for DHCP reservations.
- ZFS and `vm-bhyve` remain authoritative for storage and VM runtime facts.
- PF integration is restricted to a named anchor and must not replace the site's global ruleset.

## Current transaction boundary

The internal `PrepareApply` transaction:

1. acquires a transaction-scoped per-resource advisory lock;
2. loads or creates the stable resource UUID;
3. compares the normalized specification digest;
4. retains or advances the generation;
5. appends declared state when required;
6. builds the deterministic plan;
7. inserts or reuses the operation by idempotency key;
8. inserts the ordered step journal once;
9. marks effective state as pending;
10. commits.

It does not execute any infrastructure driver.

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
```

## Legacy boundary

V1 is frozen on `legacy/v1-shell`. V2 does not modify legacy `public` schema objects and does not consider any V1 resource managed until a future explicit import and adoption operation succeeds.