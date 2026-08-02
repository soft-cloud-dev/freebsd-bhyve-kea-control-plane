# FreeBSD bhyve + Kea Control Plane

A declarative V2 control plane for ZFS-backed FreeBSD `vm-bhyve` guests and PostgreSQL-backed Kea DHCP reservations.

`main` is V2-only. The former shell stack remains frozen on [`legacy/v1-shell`](../../tree/legacy/v1-shell) for existing installations; new V2 resources do not depend on it.

## Current capabilities

`cpctl` provides:

- strict, versioned site and VM TOML validation;
- deterministic normalization, plans, step inputs, and idempotency keys;
- checksummed PostgreSQL migrations;
- separate declared, allocated, observed, and effective state;
- durable IP, MAC, dataset, zvol, Kea subnet, and image allocations;
- persisted ordered execution steps and verified postconditions;
- typed image, ZFS, cloud-init, Kea, PF, and `vm-bhyve` operations;
- crash-resumable apply and delete execution;
- observation-only reconciliation;
- read-only Prometheus metrics and provisioned Grafana assets;
- `doctor`, `plan`, `apply`, `reconcile`, `delete`, `migrate`, `status`, `inspect`, and `metrics`;
- versioned JSON output and explicit exit codes.

Plans and concrete allocations are committed before external mutation. A process crash releases the PostgreSQL execution lock; the next invocation resumes at the first step whose postcondition has not been verified.

## Host prerequisites

V2 currently manages VM lifecycles, not installation of the FreeBSD host itself. Prepare the host with:

- hardware virtualization enabled;
- ZFS and the configured VM dataset;
- `vm-bhyve` and a configured VM switch/bridge;
- PostgreSQL for the `bkcp` schema;
- Kea DHCP4 and an authenticated local Control Agent;
- PF with a site-owned parent anchor;
- `makefs`, `unxz`, `dd`, and the commands checked by `cpctl doctor`;
- privileges sufficient for ZFS, PF, service, and `vm-bhyve` operations.

Prometheus and Grafana are optional read-only add-ons and are not required for lifecycle correctness.

## Build and verify

```sh
make verify
make build
```

The binary is written to `bin/cpctl`.

## Configure and migrate

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml

bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml
```

Replace the example all-zero image digest with an independently verified SHA-256 digest before applying a VM. The image driver rejects the sentinel.

## Plan and apply a VM

```sh
bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file config/vms/freebsd-node.example.toml \
  --generation 1 \
  --json

bin/cpctl apply \
  --config /usr/local/etc/bkcp/site.toml \
  --file config/vms/freebsd-node.example.toml \
  --json
```

`apply` allocates or reuses durable identities, persists the exact operation, executes typed steps, verifies authoritative postconditions, records observations, and returns success only when effective state is converged.

## Reconcile and inspect

```sh
bin/cpctl reconcile freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json

bin/cpctl inspect freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json
```

`inspect` exposes declaration, allocation, latest observation, effective state, operation metadata, exact persisted step input, postcondition evidence, and the resume point.

## Delete

Deletion is deliberately explicit and destructive:

```sh
bin/cpctl delete freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --destroy-storage \
  --json
```

The allocation is released and the resource archived only after VM, Kea, PF, seed, and ZFS absence have been verified.

## Prometheus and Grafana

Start the read-only exporter with a dedicated PostgreSQL DSN file:

```sh
bin/cpctl metrics \
  --config /usr/local/etc/bkcp/site.toml \
  --dsn-file /usr/local/etc/bkcp/metrics.dsn \
  --listen 127.0.0.1:9188
```

Endpoints:

```text
/metrics      Prometheus exposition
/-/healthy    process liveness
/-/ready      PostgreSQL readiness
```

The repository includes:

- a FreeBSD `bkcp_metrics` rc.d service;
- Prometheus scrape configuration and alert rules;
- a provisioned Grafana Prometheus datasource;
- the provisioned `BKCP Control Plane` dashboard;
- a least-privilege installation guide.

See [`observability/README.md`](observability/README.md) and the [Observability wiki guide](wiki/Observability.md).

## Repository layout

```text
cmd/cpctl/                 CLI entry point
internal/allocation/       deterministic durable identity helpers
internal/execution/        resumable executor and typed FreeBSD adapters
internal/metrics/          read-only PostgreSQL metrics exporter
internal/planner/          pure and allocation-bound execution plans
internal/state/postgres/   migrations, allocations, journals, evidence
migrations/                immutable checksummed PostgreSQL migrations
config/                    V2 site, VM, and rc.d examples
observability/             Prometheus rules and Grafana provisioning
schemas/                   versioned JSON schemas
docs/                      architecture, state, and migration contracts
wiki/                      operator and contributor documentation
```

## Design invariants

- PostgreSQL keeps declared, allocated, observed, and effective state separate.
- Identical normalized and allocated inputs produce identical execution plans and idempotency keys.
- Unknown or unavailable evidence never becomes confirmed absence.
- Plans, allocations, and ordered steps are persisted before external mutation.
- Every completed step stores a verified postcondition and digest.
- One PostgreSQL session advisory lock serializes execution per resource and disappears on process failure.
- Kea's hosts database remains the reservation authority.
- PF changes are restricted to the configured per-resource subanchor.
- Existing storage is never overwritten unless its persisted image identity matches the allocation.
- Storage deletion requires the explicit `--destroy-storage` authorization.
- Monitoring is read-only and does not invoke lifecycle drivers.

See [`docs/streamlined-v2.md`](docs/streamlined-v2.md), [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/STATE.md`](docs/STATE.md), and the [project wiki](wiki/Home.md).

## Validation

- `V2 CI` runs formatting, vetting, race-enabled unit tests, observability asset checks, example validation, and builds.
- `V2 PostgreSQL` runs lifecycle and metrics snapshot integration tests against PostgreSQL 16.
- `V2 FreeBSD Execution` is a manual, environment-gated self-hosted workflow for real `apply`, `reconcile`, `inspect`, and optional destructive cleanup.

## Legacy

V1 is no longer developed on `main`. Existing V1 installations remain pinned until explicit V2 import and adoption are implemented. New V2-only environments do not create V1 resources.

- [`docs/MIGRATION.md`](docs/MIGRATION.md)
- [`docs/LEGACY.md`](docs/LEGACY.md)

## License

BSD-3-Clause. See [`LICENSE`](LICENSE).
