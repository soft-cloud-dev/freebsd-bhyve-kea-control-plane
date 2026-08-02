# FreeBSD bhyve + Kea Control Plane

A declarative FreeBSD control plane for ZFS-backed `vm-bhyve` guests and Kea DHCP reservations.

`main` is V2-only. The former shell installer and orchestration stack is frozen on [`legacy/v1-shell`](../../tree/legacy/v1-shell) at commit `30068eac6c03ff813ed494739995846b8b8e74be`.

## Current state

The repository provides a stateful but non-executing `cpctl` foundation:

- strict, versioned TOML configuration;
- deterministic VM normalization and plan generation;
- stable specification, plan, step-input, and idempotency digests;
- embedded, checksummed PostgreSQL migrations;
- separate declared, allocated, observed, and effective state under the `bkcp` schema;
- durable operation and ordered-step journals;
- concurrency-safe generation assignment and plan persistence;
- read-only `doctor`, `status`, and `inspect` commands;
- versioned JSON output and explicit exit codes.

It does **not** yet allocate addresses, download images, create storage, change Kea, change PF, or run `vm-bhyve`. The internal `PrepareApply` operation persists a plan before external execution; no public `apply` command exists yet.

## Project wiki

The repository-backed [project wiki](wiki/Home.md) provides the operator and contributor guide:

- getting started and host prerequisites;
- architecture and four-state semantics;
- site and VM configuration reference;
- PostgreSQL migrations and operation journals;
- CLI and operational procedures;
- development, testing, security, and roadmap.

## Build and verify

```sh
make verify
make build
```

The binary is written to `bin/cpctl`.

## Initialize V2 state

```sh
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml

bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml
bin/cpctl status --config /usr/local/etc/bkcp/site.toml
```

Migrations are embedded in the binary, serialized by a PostgreSQL advisory lock, and recorded with SHA-256 checksums. Changing an already applied migration blocks further migration.

## Inspect a deterministic plan

```sh
bin/cpctl doctor \
  --config /usr/local/etc/bkcp/site.toml \
  --offline

bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file config/vms/freebsd-node.example.toml \
  --generation 1 \
  --json
```

The example image digest is an all-zero validation sentinel. Replace it with the independently verified SHA-256 digest before any future image-fetch or apply operation.

## Repository layout

```text
cmd/cpctl/          CLI entry point
internal/           Configuration, planning, state, probes, output contracts
migrations/         Embedded immutable PostgreSQL migrations
config/             V2 site and VM examples
schemas/            Versioned JSON schemas
docs/               Architecture, state, migration, and legacy policy
wiki/               Operator and contributor documentation
```

## Design invariants

- PostgreSQL owns declared, allocated, observed, and effective state as separate contracts.
- Identical normalized inputs produce identical plans, step digests, and idempotency keys.
- Identical declarations retain their generation; changed declarations advance it exactly once.
- Unknown observations remain distinct from confirmed absence.
- Plans and ordered steps are persisted before external mutation.
- Kea's PostgreSQL hosts database remains the reservation authority.
- PF integration must be anchor-scoped and must not replace site policy.
- Existing V1 allocations must be adopted without changing IP or MAC addresses.

See [`docs/streamlined-v2.md`](docs/streamlined-v2.md), [`docs/DESIGN.md`](docs/DESIGN.md), and [`docs/STATE.md`](docs/STATE.md).

## Migration and legacy

V1 is no longer developed on `main`. Existing V1 installations should remain pinned to the legacy branch until V2 import and adoption are implemented. Do not recreate V1 scripts in the V2 tree.

- [`docs/MIGRATION.md`](docs/MIGRATION.md)
- [`docs/LEGACY.md`](docs/LEGACY.md)

## License

BSD-3-Clause. See [`LICENSE`](LICENSE).
