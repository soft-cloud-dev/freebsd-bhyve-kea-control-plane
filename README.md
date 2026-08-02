# FreeBSD bhyve + Kea Control Plane

A declarative FreeBSD control plane for ZFS-backed `vm-bhyve` guests and Kea DHCP reservations.

`main` is V2-only. The former shell installer and orchestration stack is frozen on [`legacy/v1-shell`](../../tree/legacy/v1-shell) at commit `30068eac6c03ff813ed494739995846b8b8e74be`.

## Current state

The repository currently provides a read-only `cpctl` foundation:

- strict, versioned TOML configuration;
- deterministic VM normalization;
- stable specification, plan, and idempotency digests;
- read-only FreeBSD, ZFS, PostgreSQL, and Kea health checks;
- versioned JSON output and explicit exit codes.

It does **not** yet mutate PostgreSQL, Kea, ZFS, PF, or `vm-bhyve`. Plan output is an execution contract, not proof that infrastructure was changed.

## Build and verify

```sh
make verify
make build
```

The binary is written to `bin/cpctl`.

## Inspect the example configuration

```sh
bin/cpctl doctor \
  --config config/site.example.toml \
  --offline

bin/cpctl plan \
  --config config/site.example.toml \
  --file config/vms/freebsd-node.example.toml \
  --generation 1 \
  --json
```

The example image digest is an all-zero validation sentinel. Replace it with the independently verified SHA-256 digest before any future image-fetch or apply operation.

## Repository layout

```text
cmd/cpctl/          CLI entry point
internal/           Configuration, planning, probes, output contracts
config/             V2 site and VM examples
schemas/            Versioned JSON schemas
 docs/               Architecture, migration, and legacy policy
```

## Design invariants

- PostgreSQL will own declared, allocated, observed, and effective state as separate contracts.
- Identical normalized inputs must produce identical plans and idempotency keys.
- Unknown observations must remain distinct from confirmed absence.
- Plans and ordered steps must be persisted before external mutation.
- Kea's PostgreSQL hosts database remains the reservation authority.
- PF integration must be anchor-scoped and must not replace site policy.
- Existing V1 allocations must be adopted without changing IP or MAC addresses.

See [`docs/streamlined-v2.md`](docs/streamlined-v2.md) and [`docs/DESIGN.md`](docs/DESIGN.md).

## Migration and legacy

V1 is no longer developed on `main`. Existing V1 installations should remain pinned to the legacy branch until V2 import and adoption are implemented. Do not recreate V1 scripts in the V2 tree.

- [`docs/MIGRATION.md`](docs/MIGRATION.md)
- [`docs/LEGACY.md`](docs/LEGACY.md)
- [Iteration 2 state and journal plan](../../issues/9)

## License

BSD-3-Clause. See [`LICENSE`](LICENSE).
