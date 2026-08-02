# Getting Started

This procedure initializes V2 state and produces a deterministic VM plan. It does not create a VM.

## Prerequisites

Development requires the Go version declared in `go.mod` and GNU-compatible `make`.

A live FreeBSD control-plane host also requires hardware virtualization, ZFS, `vm-bhyve`, PostgreSQL 16, Kea DHCP4 with Control Agent, and a PF ruleset that can load a dedicated anchor.

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
- host interfaces, VM bridge, ZFS dataset, and VM root;
- PostgreSQL DSN;
- Kea endpoint and credential-file paths;
- pools, gateways, DNS servers, VLANs, and Kea subnet IDs;
- image URLs and independently verified SHA-256 digests.

Do not use the all-zero example digest for execution. Do not change `control_plane_id` after state initialization.

## 3. Validate

```sh
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
```

`doctor` is read-only. Offline mode validates configuration; live mode also probes FreeBSD, ZFS, PostgreSQL, and Kea dependencies.

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

## 6. Plan

```sh
bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --generation 1 \
  --json
```

The pure `plan` command does not read or write PostgreSQL. It emits normalized intent, digests, an idempotency key, and ordered future driver steps.

## Stop condition

There is no public `apply` command. A plan or persisted operation does not prove that Kea, ZFS, PF, images, cloud-init, or `vm-bhyve` changed.

See [CLI and Operations](CLI-and-Operations) for command details and failure handling.