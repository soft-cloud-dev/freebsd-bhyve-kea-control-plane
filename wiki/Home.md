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

Stop at `plan`.

## Documentation

1. [Getting Started](Getting-Started)
2. [Bare-Metal Three-Node Bootstrap](Bare-Metal-Three-Node-Bootstrap)
3. [Architecture](Architecture)
4. [CLI and Operations](CLI-and-Operations)
5. [Development and Roadmap](Development-and-Roadmap)

The bare-metal runbook uses the frozen `legacy/v1-shell` implementation for host and VM mutation, then installs V2 alongside it for validation, state migrations, and deterministic planning. It does not treat V1-created guests as V2-managed resources.

## Fixed rules

- Persist plans and ordered steps before external mutation.
- Keep declared, allocated, observed, and effective state separate.
- Never convert unavailable evidence into confirmed absence.
- Restrict PF ownership to the configured anchor.
- Preserve V1 identities during future adoption.

## Authoritative repository documents

- [Canonical architecture](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/streamlined-v2.md)
- [Implementation contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/DESIGN.md)
- [State contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/STATE.md)
- [Migration policy](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/MIGRATION.md)

V1 is frozen on `legacy/v1-shell`. No V1 resource is managed by V2 until explicit import and adoption succeed.