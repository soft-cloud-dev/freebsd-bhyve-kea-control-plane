# FreeBSD bhyve + Kea Control Plane

`cpctl` is the V2 control plane for describing FreeBSD `vm-bhyve` guests, validating host dependencies, producing deterministic plans, and storing durable PostgreSQL state.

## Current status

| Available now | Not available yet |
|---|---|
| Strict TOML configuration | IP and MAC allocation |
| Offline and live dependency checks | Image download and promotion |
| Deterministic VM plans and digests | Cloud-init media creation |
| Embedded PostgreSQL migrations | Kea, ZFS, PF, or `vm-bhyve` mutation |
| Declared, allocated, observed, and effective state | Public `apply`, `delete`, `adopt`, or `import-v1` commands |
| Durable operation and step journals | Continuous reconciliation |
| Read-only `status` and `inspect` | |

A persisted operation is an execution contract. It is not evidence that infrastructure changed.

## Operator path

```sh
make verify
make build

bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml
bin/cpctl status --config /usr/local/etc/bkcp/site.toml
bin/cpctl plan --config /usr/local/etc/bkcp/site.toml --file ./vm.toml --generation 1 --json
```

Stop at `plan`. V2 does not execute infrastructure changes yet.

## Wiki map

- [Getting Started](Getting-Started.md) — build, configure, migrate, and plan.
- [Architecture](Architecture.md) — system boundaries, state model, and safety rules.
- [CLI and Operations](CLI-and-Operations.md) — commands, configuration reference, migrations, troubleshooting, and backups.
- [Development and Testing](Development-and-Testing.md) — local workflow, CI, migration rules, and contribution checks.
- [Roadmap](Roadmap.md) — sequence from durable allocation to resumable execution.

## Non-negotiable rules

1. Persist plans and ordered steps before external mutation.
2. Keep declared, allocated, observed, and effective state separate.
3. Treat unavailable evidence as unknown, never as confirmed absence.
4. Keep PF changes inside the configured anchor.
5. Preserve existing V1 identities during future adoption.

## V1 boundary

The former shell implementation is frozen on `legacy/v1-shell`. V2 does not write legacy `public` schema objects and does not manage a V1 resource until explicit import and adoption succeed.

The repository remains authoritative. See `docs/DESIGN.md`, `docs/STATE.md`, `docs/MIGRATION.md`, and `docs/streamlined-v2.md`.