# Getting Started

This procedure initializes V2 state, previews a deterministic VM plan, and applies the VM through the resumable executor.

## Prerequisites

Development requires the Go version declared in `go.mod` and GNU-compatible `make`.

A live FreeBSD control-plane host requires:

- hardware virtualization;
- ZFS and the configured VM dataset;
- `vm-bhyve` and a VM switch backed by the configured bridge;
- PostgreSQL 16;
- Kea DHCP4 with authenticated Control Agent access;
- PF with a site-owned parent anchor;
- `makefs`, `unxz`, `dd`, `zfs`, `pfctl`, `service`, and `vm`;
- privileges sufficient for the configured operations.

V2 manages VM lifecycles. It does not install the base FreeBSD host or packages.

## 1. Build

```sh
git clone https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
cd freebsd-bhyve-kea-control-plane
make verify
make build
```

The binary is written to `bin/cpctl`.

## 2. Configure the site

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
```

Set:

- a stable `control_plane_id`;
- host interfaces, VM bridge, VM switch, ZFS dataset, and VM root;
- PostgreSQL DSN;
- Kea endpoint and credential-file paths;
- optional explicitly managed rc.d services;
- pools, gateways, DNS servers, VLANs, and Kea subnet IDs;
- image URLs and independently verified SHA-256 digests.

Do not use the all-zero example digest for execution. Do not change `control_plane_id` after allocations begin.

## 3. Validate

```sh
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
```

`doctor` is read-only. Offline mode validates configuration; live mode probes FreeBSD, ZFS, PostgreSQL, and Kea dependencies.

## 4. Initialize state

```sh
bin/cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml \
  --dry-run \
  --json

bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml
bin/cpctl status --config /usr/local/etc/bkcp/site.toml
```

V2 creates its objects only under the PostgreSQL `bkcp` schema. Legacy V1 objects in `public` remain untouched.

## 5. Define a VM

```sh
cp config/vms/freebsd-node.example.toml ./freebsd-node-01.toml
vi ./freebsd-node-01.toml
```

The manifest references a site image and pool and declares name, owner, profile, desired power, CPU, memory, disk, and SSH public-key path.

## 6. Preview

```sh
bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --generation 1 \
  --json
```

The pure `plan` command does not read or write PostgreSQL. It previews normalized intent and a deterministic abstract step contract. Actual generation and concrete allocation are assigned by `apply`.

## 7. Apply

```sh
bin/cpctl apply \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --json
```

`apply`:

1. allocates or reuses IP, MAC, dataset, zvol, Kea subnet, and image identities;
2. persists the declaration, allocation, operation, exact step inputs, and digests;
3. serializes preparation and execution for the resource;
4. executes typed service, image, ZFS, cloud-init, `vm-bhyve`, Kea, and PF steps;
5. verifies and persists every postcondition;
6. records authoritative observations;
7. succeeds only when effective state is `converged`.

Re-run the same command after interruption. Completed verified steps are not repeated.

## 8. Reconcile and inspect

```sh
bin/cpctl reconcile freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json

bin/cpctl inspect freebsd-node-01 \
  --config /usr/local/etc/bkcp/site.toml \
  --json
```

Reconcile records current evidence and reports drift without silently repairing it. Inspect shows the allocation, latest observation, operation journal, exact inputs, verified postconditions, and resume point.

See [CLI and Operations](CLI-and-Operations) for deletion, exit codes, backup, and failure handling.