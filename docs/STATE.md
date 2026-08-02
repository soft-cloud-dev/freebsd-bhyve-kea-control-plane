# Persistent state and operation journal

## Migration model

SQL migrations are embedded in `cpctl`. The runner creates `bkcp.schema_migrations`, takes a transaction-scoped global advisory lock, verifies every stored SHA-256 checksum, and applies pending versions in order in one transaction.

`cpctl migrate --dry-run` is read-only. It reports the current version and pending versions. An applied migration whose embedded content changes is a blocked state and must not be repaired by editing the checksum row.

## State model

- `bkcp.resources` stores stable resource identity and the current declaration pointer.
- `bkcp.vm_specs` is append-only normalized intent by generation.
- `bkcp.vm_allocations` stores durable future IP, MAC, dataset, zvol, subnet, and image assignments.
- `bkcp.vm_observations` stores evidence snapshots with explicit unknown, unavailable, absent, and present values.
- `bkcp.vm_effective` stores the currently derived state and reason.
- `bkcp.operations` stores a deterministic operation for an exact resource generation.
- `bkcp.operation_steps` stores ordered driver actions and deterministic input digests.

## PrepareApply

`PrepareApply` is an internal transaction and does not execute drivers:

```text
acquire resource advisory lock
load or create stable resource UUID
compare normalized specification digest
retain or advance generation
append declaration when changed
build deterministic plan
insert or reuse operation by idempotency key
insert ordered steps once
set effective state to pending
commit
```

Thirty-two concurrent calls with identical input must converge on one resource UUID, one generation, one operation, one idempotency key, and one eight-step set.

## Resume point

`cpctl inspect` returns the latest operation, its ordered steps, and the first step not marked `succeeded` or `skipped`. This is the future executor's resume point. No current command changes step status or performs external actions.

## Security boundary

DSNs and credential contents are not stored in state. Normalized VM specifications may store a path to an SSH public key, but not key contents. CLI connection failures return a redacted dependency-unavailable error rather than printing the PostgreSQL DSN.
