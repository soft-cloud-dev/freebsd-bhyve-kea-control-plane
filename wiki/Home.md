# FreeBSD bhyve + Kea Control Plane

`cpctl` is the V2 control plane for FreeBSD `vm-bhyve` guests, ZFS storage, Kea reservations, PF isolation, cloud-init media, and durable PostgreSQL state.

V2 executes new VM lifecycles directly. It does not require `legacy/v1-shell`.

## Available now

- strict site and VM TOML validation;
- deterministic pure plans and allocation-bound execution plans;
- checksummed PostgreSQL migrations;
- separate declared, allocated, observed, and effective state;
- durable IP, MAC, dataset, zvol, Kea subnet, and image allocations;
- exact persisted step inputs and verified postconditions;
- typed image, ZFS, cloud-init, Kea, PF, and `vm-bhyve` drivers;
- per-resource PostgreSQL execution locks and crash resume;
- observation-only reconciliation;
- read-only Prometheus metrics and provisioned Grafana assets;
- `doctor`, `plan`, `apply`, `reconcile`, `delete`, `migrate`, `status`, `inspect`, and `metrics`.

The FreeBSD host remains a prerequisite. V2 does not install the base operating system, packages, network interfaces, PostgreSQL, Kea, or the parent PF policy.

## Quick path

```sh
make verify
make build

bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml

bin/cpctl apply \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./vm.toml \
  --json

bin/cpctl reconcile freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json

bin/cpctl inspect freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json

bin/cpctl metrics \
  --config /usr/local/etc/bkcp/site.toml \
  --dsn-file /usr/local/etc/bkcp/metrics.dsn
```

Replace the example all-zero image digest before `apply`; it is deliberately rejected by the image driver.

## Documentation

1. [Getting Started](Getting-Started)
2. [V2-Only Bare-Metal Three-Node Bootstrap](Bare-Metal-Three-Node-Bootstrap)
3. [Architecture](Architecture)
4. [CLI and Operations](CLI-and-Operations)
5. [Observability](Observability)
6. [Development and Roadmap](Development-and-Roadmap)

## Fixed rules

- Persist declarations, allocations, operations, and ordered steps before external mutation.
- Re-hash persisted step input immediately before execution.
- Keep declared, allocated, observed, and effective state separate.
- Never convert unavailable evidence into confirmed absence.
- Serialize execution per resource and resume after process failure.
- Restrict PF ownership to configured per-resource subanchors.
- Require explicit `--destroy-storage` authorization for deletion.
- Keep monitoring read-only and independent from lifecycle execution.
- Allocate and manage new resources directly through V2.

## Authoritative repository documents

- [Canonical architecture](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/streamlined-v2.md)
- [Implementation contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/DESIGN.md)
- [State contract](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/STATE.md)
- [Migration policy](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/docs/MIGRATION.md)

V1 remains frozen for existing installations only. Import and adoption of those resources are still separate future operations.
