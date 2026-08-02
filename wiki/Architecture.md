# Architecture

`cpctl` is a static Go control-plane CLI. It validates typed configuration, allocates durable identities, persists deterministic execution contracts, and coordinates narrow FreeBSD infrastructure drivers.

```text
site.toml + VM manifest
          |
          v
 strict decode + normalize
          |
          v
 resource preparation lock
          |
          v
 PostgreSQL allocation
 IP | MAC | dataset | zvol | Kea subnet | image
          |
          v
 allocation-bound plan + exact step inputs
          |
          v
 operation + ordered-step journal
          |
          v
 per-resource session execution lock
          |
          v
 service | image | ZFS | cloud-init | vm-bhyve | Kea | PF
          |
          v
 authoritative observations
          |
          v
 effective converged | drifted | degraded | absent | blocked
```

## Four-state model

| State | Meaning | Implementation |
|---|---|---|
| Declared | Normalized requested intent by generation | Append-only `bkcp.vm_specs` |
| Allocated | Durable IP, MAC, storage, subnet, and image assignments | `bkcp.vm_allocations` under resource and pool locks |
| Observed | Evidence from authoritative external systems | Append-only `bkcp.vm_observations` |
| Effective | Derived reconciliation result and reason | Current `bkcp.vm_effective` |

Unavailable evidence remains explicit. It is never interpreted as confirmed absence.

## Determinism

The same normalized manifest, control-plane ID, generation, durable allocation, action, site execution contract, and ordered steps produce the same:

- specification digest;
- exact step input JSON;
- step input digest;
- execution plan digest;
- idempotency key.

A pure `plan` previews abstract intent. `apply` consults PostgreSQL and creates the allocation-bound executable plan.

Identical intent retains its generation and allocation. Changed intent advances the generation exactly once under the resource preparation lock. Implicit pool or image replacement is blocked.

## Persist before mutation

Executable apply preparation:

1. acquires the execution-key transaction lock, blocking preparation during active mutation;
2. acquires the transaction-scoped resource lock;
3. loads or creates the stable resource UUID;
4. retains or advances the declared generation;
5. assigns or reuses durable allocation identities under a pool lock;
6. builds the allocation-bound executable plan;
7. inserts or reuses the operation by idempotency key;
8. persists ordered steps with exact input JSON and digests;
9. marks effective state pending;
10. commits before any external mutation.

The executor then acquires the same resource execution key as a PostgreSQL session advisory lock. This serializes mutation across processes. A process crash closes the session and releases the lock.

## Resumable execution

For each incomplete step, the executor:

1. claims the persisted step;
2. decodes its exact JSON input;
3. recomputes and verifies its input digest;
4. invokes one typed driver action;
5. verifies the authoritative postcondition;
6. stores postcondition JSON and digest;
7. proceeds to the next incomplete step.

A retry skips steps already marked `succeeded` or `skipped`. It does not restart blindly.

## Typed drivers

- **Service** — optionally starts and verifies explicitly named FreeBSD rc.d services.
- **Image** — downloads to a temporary path, verifies compressed SHA-256, decompresses, hashes the raw image, and atomically promotes the cache.
- **ZFS** — creates the VM dataset and sparse zvol, verifies exact volume size, initializes only a newly created zvol, and stores the raw-image identity as a ZFS property.
- **Cloud-init** — renders deterministic NoCloud source, creates a `cidata` ISO, and binds reuse to source and ISO digests.
- **vm-bhyve** — writes the typed guest configuration and converges requested power.
- **Kea** — creates, updates, deletes, and verifies PostgreSQL-backed reservations through the Control Agent.
- **PF** — manages only the configured per-resource subanchor.
- **Observer** — collects VM, storage, Kea, seed, power, image, and PF evidence and preserves unavailable versus absent.

Drivers accept typed inputs rather than arbitrary shell command strings. Credential contents are read from referenced files and are not persisted in operation input.

## Reconciliation

`reconcile` is an observation-only journaled operation. It records current evidence and returns drift when observations do not match intent. It does not silently repair or replace identity-bearing resources.

Repeated `apply` with unchanged executable identity uses reconciliation rather than replaying completed mutations.

## Deletion

Deletion is a separate deterministic operation and requires explicit `--destroy-storage` authorization. V2 stops the VM, removes Kea and PF state, removes the VM and seed media, destroys the allocated ZFS dataset, verifies absence, releases the allocation, and archives the resource.

## Authority boundaries

- PostgreSQL owns V2 intent, allocations, journals, evidence, and effective state.
- Kea remains authoritative for DHCP reservations.
- ZFS remains authoritative for datasets, zvols, size, and stored image identity.
- `vm-bhyve` remains authoritative for guest discovery and power state.
- PF ownership is limited to the configured parent and per-resource subanchor.
- The verified image cache owns promoted artifact bytes and digest markers.
- The FreeBSD host installation and site-owned parent policy remain prerequisites rather than per-VM operations.

## PostgreSQL objects

- `bkcp.schema_migrations` — immutable migration history;
- `bkcp.resources` — stable identity and current generation;
- `bkcp.vm_specs` — append-only declared intent;
- `bkcp.vm_allocations` — durable assignments;
- `bkcp.vm_observations` — evidence snapshots;
- `bkcp.vm_effective` — current derived state;
- `bkcp.operations` — operation headers and idempotency keys;
- `bkcp.operation_steps` — exact inputs, status, retries, and verified postconditions.

Applied migrations are immutable and checksum-verified. Add a new migration version instead of editing an applied file or checksum row.

## Legacy boundary

V1 is frozen on `legacy/v1-shell`. New V2 resources do not depend on it. Future import and adoption of existing V1 resources must preserve guest names, IP addresses, MAC addresses, storage identities, image identity, and Kea reservations.