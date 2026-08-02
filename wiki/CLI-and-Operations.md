# CLI and Operations

Default configuration path:

```text
/usr/local/etc/bkcp/site.toml
```

## Command surface

| Command | Purpose | External writes |
|---|---|---|
| `cpctl doctor` | Validate configuration and probe dependencies | None |
| `cpctl plan` | Build a pure deterministic preview | None |
| `cpctl apply --file VM.toml` | Allocate, prepare, execute, observe, and converge a VM | PostgreSQL, image cache, ZFS, cloud-init, Kea, PF, `vm-bhyve` |
| `cpctl reconcile NAME` | Collect authoritative observations and derive current effective state | PostgreSQL evidence and journals |
| `cpctl delete NAME --destroy-storage` | Verify and remove a VM plus its allocated storage | PostgreSQL, ZFS, cloud-init, Kea, PF, `vm-bhyve` |
| `cpctl migrate` | Inspect or apply embedded migrations | PostgreSQL `bkcp` schema only |
| `cpctl status` | List known resources | None |
| `cpctl inspect NAME` | Show declaration, allocation, observations, operation evidence, and resume point | None |
| `cpctl metrics` | Serve Prometheus metrics and health endpoints | PostgreSQL `SELECT` only |
| `cpctl version` | Print version | None |

## Initial sequence

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl plan --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --generation 1 --json
cpctl apply --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --json
```

The pure `plan` command is a preview and accepts an explicit generation. `apply` consults PostgreSQL, assigns or reuses the actual generation and durable allocation, and persists the exact executable plan before mutation.

## Configuration contract

`cpctl` strictly decodes TOML. Unknown keys and invalid values are rejected.

The site configuration defines:

- stable `control_plane_id`;
- host interfaces, VM bridge/switch contract, ZFS dataset, and VM root;
- PostgreSQL DSN;
- Kea endpoint and credential-file paths;
- PF parent anchor policy;
- address pools and Kea subnet IDs;
- image URLs, formats, loaders, and verified compressed digests.

A VM manifest defines name, owner, image, profile, pool, desired power, CPU, memory, disk, and SSH public-key path.

Rules:

- keep `control_plane_id` stable after allocation starts;
- reference credential files rather than embedding credentials;
- replace the all-zero image digest before `apply`;
- keep PF changes inside the configured parent and per-resource subanchor;
- ensure manifest image and pool names exist in the selected site configuration;
- do not change a resource's pool or image implicitly; explicit replacement is required;
- do not delete storage without the explicit destructive flag;
- run the metrics exporter with a separate read-only DSN file where possible.

## Apply

```sh
cpctl apply \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./vm.toml \
  --json
```

`apply` performs this durable sequence:

1. validate and normalize the manifest;
2. acquire the per-resource preparation lock;
3. assign or reuse IP, MAC, dataset, zvol, Kea subnet, and image identity;
4. persist the declaration, allocation, operation, ordered step input, digests, and effective pending state;
5. acquire the session execution lock;
6. resume from the first unverified step;
7. execute one typed mutation at a time;
8. verify and persist each postcondition;
9. collect observations;
10. mark the resource converged only when authoritative state agrees.

A second process targeting the same resource is blocked while execution is active. A process crash releases the session lock; another invocation resumes from persisted evidence.

## Reconcile

```sh
cpctl reconcile freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json
```

Reconcile is an observation-only journaled operation. It does not repair drift. It records present, absent, unknown, or unavailable evidence and returns exit code `4` when the observed state differs from declared intent.

Repeated `apply` with unchanged executable identity uses reconciliation rather than repeating completed mutations.

## Inspect

```sh
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl inspect freebsd-node-01 --config /usr/local/etc/bkcp/site.toml --json
```

`inspect` reports:

- current declaration and generation;
- durable allocation;
- latest observation;
- effective state and reason;
- latest operation and status;
- every ordered step's exact input JSON and digest;
- verified postcondition JSON and digest;
- first incomplete resume step.

Do not mark steps successful manually. Repair or retry through the declared operation so postconditions remain evidence-backed.

## Metrics

```sh
cpctl metrics \
  --config /usr/local/etc/bkcp/site.toml \
  --dsn-file /usr/local/etc/bkcp/metrics.dsn \
  --listen 127.0.0.1:9188
```

`metrics` is a long-running read-only HTTP service. It exports state derived from the PostgreSQL `bkcp` schema and does not invoke lifecycle drivers.

```text
/metrics      Prometheus exposition
/-/healthy    process liveness
/-/ready      PostgreSQL readiness
```

The default listen address is loopback-only. The optional DSN file should belong to a role with `CONNECT`, schema `USAGE`, and table `SELECT` privileges only. See [Observability](Observability) for Prometheus, Grafana, alerting, and rc.d installation.

## Delete

Deletion requires explicit storage authorization:

```sh
cpctl delete freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --destroy-storage \
  --json
```

The ordered delete operation stops the VM, removes the Kea reservation and PF subanchor, removes the VM and cloud-init media, destroys the allocated ZFS dataset, verifies absence, releases the allocation, and archives the resource.

The shared verified image cache is retained.

## Migrations

```sh
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
```

Migrations are embedded, ordered, transactionally applied, advisory-lock protected, and recorded with SHA-256 checksums.

Repeated migration is a no-op when versions and checksums match. A checksum mismatch is blocked. Restore the released migration and add a new version; never edit the stored checksum.

## JSON envelope

```json
{
  "schema": 1,
  "command": "apply",
  "ok": true,
  "data": {},
  "errors": []
}
```

Consumers must tolerate backward-compatible field additions while `schema` remains `1`. The long-running metrics HTTP service uses Prometheus text exposition rather than the command JSON envelope.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success and verified postcondition |
| `2` | Invalid input or contract violation |
| `3` | Required dependency unavailable |
| `4` | Drift detected |
| `5` | Operation, allocation, or migration blocked |
| `6` | Partial or retryable execution failure |
| `7` | Resource not found |
| `70` | Internal error |

## Failure handling

| Failure | Action |
|---|---|
| Invalid TOML | Correct the source; do not bypass strict decoding |
| PostgreSQL unavailable | Restore connectivity or authentication, then retry |
| Migration checksum mismatch | Stop and restore the released migration content |
| Pool exhausted | Expand or select a pool; allocation remains blocked |
| Image digest mismatch | Stop; verify provenance and configured digest |
| Existing storage identity mismatch | Stop; do not overwrite or relabel unknown storage |
| Observer unavailable | Restore the authoritative dependency; do not treat it as absence |
| Driver failure | Re-run the same command; execution resumes at the first unverified step |
| Resource drift | Inspect authoritative systems and decide whether to re-apply or change intent |
| Metrics snapshot unavailable | Restore exporter database access; Prometheus scrape returns HTTP 503 |
| Resource not found | Verify the name and whether the resource was deleted or never prepared |

## Backup and recovery

Before upgrades, take a PostgreSQL-consistent backup, retain the matching `cpctl` release, keep site and VM manifests in version control, and preserve externally assigned identities.

Down migrations are intentionally not automatic. PostgreSQL operation rows are evidence of attempted work; only verified step postconditions and current observations establish actual infrastructure state.
