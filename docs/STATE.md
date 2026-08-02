# Persistent state and operation journal

## Migration model

SQL migrations are embedded in `cpctl`. The runner creates `bkcp.schema_migrations`, takes a transaction-scoped global advisory lock, verifies stored SHA-256 checksums, and applies pending versions in order in one transaction.

`cpctl migrate --dry-run` is read-only. An applied migration whose embedded content changes is blocked. Restore the released migration and add a new numbered migration; never edit the checksum row.

## State model

- `bkcp.resources` stores stable resource identity, management status, current declaration generation, and archive metadata.
- `bkcp.vm_specs` stores append-only normalized declared intent by generation.
- `bkcp.vm_allocations` stores durable pool, IP, MAC, dataset, zvol, Kea subnet, image, image digest, and allocation generation.
- `bkcp.vm_observations` stores timestamped VM, storage, Kea, seed, image, PF, and power evidence with explicit unknown, unavailable, absent, and present values.
- `bkcp.vm_effective` stores the current derived state, reason, plan digest, latest evidence reference, and successful reconciliation time.
- `bkcp.operations` stores deterministic apply, reconcile, delete, import, or adoption operation headers.
- `bkcp.operation_steps` stores ordered typed actions, exact input JSON and digest, attempts, errors, and verified postcondition JSON and digest.

## Declaration and allocation preparation

Executable apply preparation runs in one PostgreSQL transaction:

```text
acquire execution-key transaction lock
acquire resource transaction lock
load or create stable resource UUID
compare normalized specification digest
retain or advance declaration generation
acquire pool transaction lock
reuse or assign IP, MAC, dataset, zvol, subnet, and image identity
build allocation-bound executable plan
insert or reuse operation by idempotency key
persist exact ordered step inputs and digests
set effective state pending
commit before external mutation
```

The execution-key lock prevents operation preparation from changing state while an executor is active for the same resource.

Allocation rules:

- identical intent reuses the allocation;
- IP and MAC uniqueness are database-enforced and checked under the pool lock;
- MAC candidates are deterministic locally administered unicast addresses;
- dataset and zvol names derive from the configured VM dataset and resource name;
- exhaustion is a typed blocked condition;
- implicit pool or image replacement is blocked;
- allocation release occurs only after verified delete completion.

## Execution lock

The executor obtains a PostgreSQL session advisory lock derived from the stable resource name. Only one process may mutate a resource at a time.

The lock is held across all external steps and released when execution ends. If the process or database session terminates, PostgreSQL releases it automatically, allowing a later invocation to resume.

## Step lifecycle

A step moves through:

```text
pending -> running -> succeeded
                   -> skipped
                   -> failed
```

Immediately before a driver runs, the executor:

1. loads `input_json`;
2. decodes it into the typed step contract;
3. canonicalizes and re-hashes it;
4. compares it with `input_digest`;
5. blocks execution on mismatch.

After mutation, the driver verifies authoritative state. The executor stores the canonical postcondition evidence and SHA-256 digest before advancing.

A failed step records a bounded error code and detail. Retry starts from the first step not marked `succeeded` or `skipped`.

## Operations

### Apply

Apply binds a declaration to its durable allocation and executes service readiness when enabled, image verification, ZFS storage, cloud-init, VM definition/configuration, Kea reservation, PF rules, power, and final observation.

An unchanged completed apply is followed by observation-only reconciliation rather than replaying successful mutations.

### Reconcile

Reconcile persists a one-step observation operation. It records current evidence and reports drift without silently repairing it.

### Delete

Delete requires explicit storage-destruction authorization. It stops the VM, removes Kea and PF state, removes VM and seed media, destroys allocated ZFS state, verifies absence, releases allocation, and archives the resource.

The shared verified image cache remains outside per-resource deletion.

## Observations

Observation domains preserve four-valued semantics:

```text
unknown       no qualified evidence is available
unavailable   the observer could not query its authority
absent        the authority confirmed nonexistence
present       the authority confirmed existence
```

Power additionally records `running` or `stopped`.

Observer command or API failure is never converted into absence. Failed observation evidence is persisted before the operation returns drift or partial failure.

## Inspection

`cpctl inspect NAME --json` returns:

- resource summary;
- current declaration;
- durable allocation;
- latest observation;
- effective state;
- latest operation;
- exact ordered input JSON and digests;
- verified postcondition JSON and digests;
- first incomplete resume step.

Operation rows record attempted work. Only verified postconditions and current authoritative observations establish actual external state.

## Security boundary

- Credential contents are never stored in state; operation input contains only credential-file paths.
- PostgreSQL connection failures exposed by the CLI do not print the DSN.
- SSH private keys are never accepted or persisted.
- The VM manifest persists an SSH public-key path; cloud-init reads the public key during seed rendering and records a source digest for the resulting artifact.
- Error details are length-bounded.
- PF ownership is scoped to the configured per-resource subanchor.
- Service management accepts only explicitly configured restricted names.
