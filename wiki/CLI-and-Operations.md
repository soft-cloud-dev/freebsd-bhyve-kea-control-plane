# CLI and Operations

## Command surface

| Command | Purpose | Writes external infrastructure |
|---|---|---|
| `cpctl doctor` | Validate configuration and probe dependencies | No |
| `cpctl plan` | Build a deterministic plan | No |
| `cpctl migrate` | Inspect or apply embedded PostgreSQL migrations | PostgreSQL schema only |
| `cpctl status` | List known resources | No |
| `cpctl inspect NAME` | Show declaration, allocation, effective state, operation, steps, and resume point | No |
| `cpctl version` | Print the binary version | No |

Default configuration path:

```text
/usr/local/etc/bkcp/site.toml
```

## Standard operator sequence

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl plan --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --generation 1 --json
```

Stop at `plan`.

## Site configuration

`cpctl` strictly decodes TOML. Unknown keys and invalid values are rejected.

| Section | Important fields |
|---|---|
| Root | `schema`, stable `control_plane_id` |
| `[host]` | interfaces, VM bridge, ZFS dataset, VM root |
| `[database]` | PostgreSQL DSN |
| `[kea]` | API URL, credential-file paths, hosts database, timeout |
| `[network]` | PF anchor and management policy |
| `[[pools]]` | subnet, range, gateway, DNS, VLAN, Kea subnet ID |
| `[[images]]` | name, URL, compressed SHA-256, format, loader |

Rules:

- Keep `control_plane_id` stable after initialization.
- Do not store Kea credentials directly in TOML; reference files.
- Reject the all-zero image digest before any future execution.
- Keep PF ownership inside the configured anchor.

## VM manifest

| Field | Meaning |
|---|---|
| `name` | Stable resource name |
| `owner` | Administrative label |
| `image` | Site image name |
| `profile` | Guest profile intent |
| `pool` | Site pool name |
| `desired_power` | Requested power state |
| `cpus`, `memory_mb`, `disk_gb` | Guest resources |
| `ssh_public_key_file` | Public-key path; contents are not persisted |

`plan` rejects unknown image or pool references.

## Migration behavior

Migrations are embedded in `cpctl`, run in version order, and are protected by a PostgreSQL advisory lock. Applied versions are recorded with SHA-256 checksums in `bkcp.schema_migrations`.

```sh
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
```

Repeated migration is a no-op when versions and checksums match. A checksum mismatch is blocked. Restore the released migration and add a new migration version; never edit the checksum row.

V2 tables:

- `bkcp.resources` — stable identity and current generation;
- `bkcp.vm_specs` — append-only declared intent;
- `bkcp.vm_allocations` — durable assignments;
- `bkcp.vm_observations` — evidence snapshots;
- `bkcp.vm_effective` — derived state and reason;
- `bkcp.operations` — operation headers;
- `bkcp.operation_steps` — ordered resumable work.

## Inspection

```sh
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl inspect freebsd-node-01 --config /usr/local/etc/bkcp/site.toml --json
```

`inspect` reports the first step not marked `succeeded` or `skipped` as the future resume point. No current command executes or advances that step.

## JSON envelope

```json
{
  "schema": 1,
  "command": "status",
  "ok": true,
  "data": {},
  "errors": []
}
```

Consumers must tolerate backward-compatible field additions while `schema` remains `1`.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Success |
| `2` | Invalid input or contract violation |
| `3` | Required dependency unavailable |
| `4` | Drift detected |
| `5` | Operation or migration blocked |
| `6` | Partial failure |
| `7` | Resource not found |
| `70` | Internal error |

## Failure handling

- Invalid TOML: correct the source; do not bypass strict decoding.
- PostgreSQL unavailable: restore connectivity or authentication and retry.
- Migration checksum mismatch: stop and restore the released migration content.
- Resource not found: verify the name and whether preparation has occurred.
- Unexpected operation state: inspect PostgreSQL and authoritative external systems independently.
- Unknown evidence: retain it as unknown; do not mark absence or success manually.

## Backup and recovery

Before upgrades:

- take a PostgreSQL-consistent backup;
- retain the exact `cpctl` release associated with applied migrations;
- keep site and VM manifests in version control;
- preserve externally assigned identities;
- verify external postconditions before repairing operation state.

Down migrations are intentionally not automatic.