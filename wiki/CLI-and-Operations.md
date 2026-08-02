# CLI and Operations

Default configuration path:

```text
/usr/local/etc/bkcp/site.toml
```

## Command surface

| Command | Purpose | External writes |
|---|---|---|
| `cpctl doctor` | Validate configuration and probe dependencies | None |
| `cpctl plan` | Build a deterministic plan | None |
| `cpctl migrate` | Inspect or apply embedded migrations | PostgreSQL `bkcp` schema only |
| `cpctl status` | List known resources | None |
| `cpctl inspect NAME` | Show state, operation, steps, and resume point | None |
| `cpctl version` | Print version | None |

## Standard sequence

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl plan --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --generation 1 --json
```

Stop at `plan`.

## Configuration contract

`cpctl` strictly decodes TOML. Unknown keys and invalid values are rejected.

The site configuration defines:

- stable `control_plane_id`;
- host interfaces, bridge, ZFS dataset, and VM root;
- PostgreSQL DSN;
- Kea endpoint and credential-file paths;
- PF anchor policy;
- address pools and Kea subnet IDs;
- image URLs, formats, loaders, and verified digests.

A VM manifest defines name, owner, image, profile, pool, desired power, CPU, memory, disk, and SSH public-key path.

Rules:

- keep `control_plane_id` stable after initialization;
- reference credential files rather than embedding credentials;
- reject the all-zero image digest before execution;
- keep PF changes inside the configured anchor;
- ensure manifest image and pool names exist in the site configuration.

## Migrations

```sh
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
```

Migrations are embedded, ordered, transactionally applied, advisory-lock protected, and recorded with SHA-256 checksums.

Repeated migration is a no-op when versions and checksums match. A checksum mismatch is blocked. Restore the released migration and add a new version; never edit the stored checksum.

## Planning and inspection

```sh
cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./vm.toml \
  --generation 1 \
  --json

cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl inspect freebsd-node-01 --config /usr/local/etc/bkcp/site.toml --json
```

The pure `plan` command does not consult PostgreSQL. The caller supplies the generation.

`inspect` reports the latest operation and the first step not marked `succeeded` or `skipped` as the future resume point. No current command executes or advances it.

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

| Failure | Action |
|---|---|
| Invalid TOML | Correct the source; do not bypass strict decoding |
| PostgreSQL unavailable | Restore connectivity or authentication, then retry |
| Migration checksum mismatch | Stop and restore the released migration content |
| Resource not found | Verify the name and whether preparation occurred |
| Unexpected operation state | Inspect PostgreSQL and authoritative external systems independently |
| Unknown evidence | Preserve it as unknown; do not mark absence or success manually |

## Backup and recovery

Before upgrades, take a PostgreSQL-consistent backup, retain the matching `cpctl` release, keep manifests in version control, and preserve externally assigned identities.

Down migrations are intentionally not automatic. Never mark a journal step successful without verifying the authoritative external postcondition.