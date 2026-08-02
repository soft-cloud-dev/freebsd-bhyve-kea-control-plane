# FreeBSD bhyve + Kea Control Plane

`cpctl` is the V2 control plane for FreeBSD `vm-bhyve` guests, ZFS-backed storage, Kea reservations, and durable PostgreSQL state.

V2 is currently **stateful but non-executing**.

## Available now

- strict site and VM TOML validation;
- offline and live dependency checks;
- deterministic plans, step digests, and idempotency keys;
- checksummed PostgreSQL migrations;
- separate declared, allocated, observed, and effective state;
- durable operation and ordered-step journals;
- `doctor`, `plan`, `migrate`, `status`, and `inspect`.

Not yet implemented: address allocation, image promotion, cloud-init generation, Kea/ZFS/PF/`vm-bhyve` mutation, `apply`, `delete`, import, adoption, and reconciliation.

A persisted plan is an execution contract. It is not evidence that infrastructure changed.

## Quick path

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

Stop at `plan` until the V2 execution vertical slice is implemented.

## Documentation

1. [Getting Started](Getting-Started)
2. [V2-Only Bare-Metal Three-Node Bootstrap](Bare-Metal-Three-Node-Bootstrap)
3. [Architecture](Architecture)
4. [CLI and Operations](CLI-and-Operations)
5. [Development and Roadmap](Development-and-Roadmap)

The bare-metal runbook defines the V2-only target. It does not require `legacy/v1-shell`. It separates manual FreeBSD host prerequisites from the V2 capabilities still required for allocation, observation, typed infrastructure drivers, resumable execution, and public `apply`.

## Fixed rules

- Persist plans and ordered steps before external mutation.
- Keep declared, allocated, observed, and effective state separate.
- Never convert unavailable evidence into confirmed absence.
- Restrict PF ownership to the configured anchor.
- Allocate and manage new resources directly through V2.

## Authoritative repository documents

- [Canonical architecture](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/streamlined-v2.md)
- [Implementation contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/DESIGN.md)
- [State contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/STATE.md)
- [Migration policy](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/MIGRATION.md)

V1 is frozen on `legacy/v1-shell` for existing installations only. New V2-only environments do not need to create V1 resources or pass through V1 adoption.
