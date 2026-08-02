# State and Migrations

## Database ownership

V2 stores all control-plane objects in the dedicated PostgreSQL schema `bkcp`.

It does not rename, alter, backfill, or attach triggers to legacy V1 objects in `public`.

## Migration model

SQL migrations are embedded in the `cpctl` binary. The runner:

1. opens a PostgreSQL transaction;
2. acquires a global transaction-scoped advisory lock;
3. creates or reads `bkcp.schema_migrations`;
4. verifies the stored SHA-256 checksum of every applied migration;
5. applies pending migrations in version order;
6. records version, name, checksum, and application time;
7. commits atomically.

Repeated migration is a no-op when all versions and checksums match.

An applied migration whose embedded content has changed is a blocked state. Do not repair it by editing the checksum row. Restore the original migration and add a new migration version.

## Migration commands

Review without mutation:

```sh
bin/cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml \
  --dry-run \
  --json
```

Apply pending versions:

```sh
bin/cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml
```

## Tables

### `bkcp.schema_migrations`

Immutable migration history and checksums.

### `bkcp.resources`

Stable resource identity, management status, current declaration generation, and archive metadata.

### `bkcp.vm_specs`

Append-only normalized declared-state history. The key is resource UUID plus generation.

Identical normalized intent retains the current generation. A changed intent advances the generation exactly once under the resource lock. Reverting to an older specification after an intervening change creates a new later generation.

### `bkcp.vm_allocations`

Durable assignments such as pool, IP, MAC, dataset, zvol, Kea subnet, image, and verified image digest.

The schema exists, but the current implementation does not allocate or release these values.

### `bkcp.vm_observations`

Append-only evidence snapshots from external systems. Availability is explicit so an unavailable observer remains different from confirmed absence.

### `bkcp.vm_effective`

Current derived state and reason. Expected lifecycle values include:

- `pending`;
- `applying`;
- `converged`;
- `degraded`;
- `drifted`;
- `deleting`;
- `absent`;
- `blocked`.

### `bkcp.operations`

Operation header bound to an exact declared generation. It stores action, specification digest, plan digest, idempotency key, status, attempts, timestamps, and bounded error details.

### `bkcp.operation_steps`

Ordered resumable work. Each row stores sequence, driver, action, deterministic input digest, status, attempts, timestamps, and bounded error details.

## Operation identity

Per-resource transactions use an advisory-lock identity derived from a text-safe, length-prefixed combination of:

- control-plane ID;
- resource kind;
- VM name.

The operation idempotency key is deterministic for the exact normalized intent, generation, control-plane ID, action, and ordered step contract.

## Resume semantics

`cpctl inspect NAME` loads the latest operation and ordered step list. The first step not marked `succeeded` or `skipped` is the future executor's resume point.

No current command changes step status or executes the step.

## Backup and recovery

Before upgrades or future execution features:

- back up the PostgreSQL database with a normal PostgreSQL-consistent method;
- retain the exact `cpctl` binary or release version associated with applied migrations;
- retain site and VM manifests in version control;
- do not treat operation rows as proof that external actions completed;
- compare state with external observations before manually repairing anything.

Down migrations are intentionally not automatic. Recovery should use forward migrations or database restore after diagnosing the failed contract.