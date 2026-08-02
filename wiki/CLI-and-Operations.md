# CLI and Operations

## Command summary

```text
cpctl doctor [--config PATH] [--offline] [--json]
cpctl plan --file VM.toml [--config PATH] [--generation N] [--json]
cpctl migrate [--config PATH] [--dry-run] [--json]
cpctl status [--config PATH] [--json]
cpctl inspect NAME [--config PATH] [--json]
cpctl version
```

Default configuration path:

```text
/usr/local/etc/bkcp/site.toml
```

## `doctor`

Validates site configuration and host dependencies.

Offline structural check:

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
```

Live check:

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --timeout 20s
```

Machine-readable output:

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --json
```

A failed required probe returns the dependency-unavailable exit code.

## `plan`

Builds a deterministic apply plan without writing PostgreSQL or changing the host.

```sh
cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --generation 1 \
  --json
```

The output includes:

- resource name;
- generation;
- specification digest;
- plan digest;
- idempotency key;
- ordered steps with driver, action, and input digest.

The caller supplies the generation because this pure command does not consult state. The internal transactional preparation path assigns generations from PostgreSQL.

## `migrate`

Reports or applies embedded PostgreSQL migrations.

```sh
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run
cpctl migrate --config /usr/local/etc/bkcp/site.toml
```

Use `--dry-run` before deploying a new binary. Checksum mismatch is blocked rather than silently accepted.

## `status`

Lists known resources and their current state summary.

```sh
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml --json
```

This command is read-only.

## `inspect`

Shows one resource's current declaration, allocation if present, effective state, latest operation, ordered steps, and future resume point.

```sh
cpctl inspect freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json
```

An unknown resource returns the not-found exit code.

## JSON envelope

Machine-readable output uses a versioned envelope:

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

## Operator sequence

Use this sequence on a fresh V2 environment:

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml
cpctl plan --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --generation 1 --json
```

Stop at `plan`. There is no supported external execution command yet.

## Failure handling

- Configuration errors: fix the TOML; do not bypass strict decoding.
- PostgreSQL unavailable: restore connectivity or authentication, then retry.
- Migration checksum mismatch: stop, restore the released migration content, and diagnose the binary/database version pairing.
- Resource not found: verify the resource name and that state preparation has actually occurred.
- Unexpected operation state: inspect PostgreSQL and external systems independently; do not mark steps successful without verified postconditions.