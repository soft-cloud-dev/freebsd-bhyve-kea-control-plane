# Getting Started

This path initializes the current V2 control-plane state and produces a deterministic VM plan. It does not create a VM.

## 1. Prepare the environment

Development requires the Go version declared in `go.mod` and GNU-compatible `make`.

A live FreeBSD control-plane host also needs:

- hardware virtualization;
- ZFS and a VM dataset;
- `vm-bhyve`;
- PostgreSQL 16;
- Kea DHCP4 and Control Agent;
- a PF ruleset that can load a dedicated `bkcp` anchor.

## 2. Build and verify

```sh
git clone https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
cd freebsd-bhyve-kea-control-plane
make verify
make build
```

The binary is written to `bin/cpctl`.

## 3. Create `site.toml`

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
```

Set the real values for:

- `control_plane_id`;
- FreeBSD interfaces, bridge, ZFS dataset, and mount path;
- PostgreSQL DSN;
- Kea endpoint and credential-file paths;
- address pools and Kea subnet IDs;
- images and independently verified SHA-256 digests.

Keep `control_plane_id` stable after state initialization. The all-zero image digest in the example is a validation sentinel and must not be trusted for execution.

## 4. Validate the host contract

Offline configuration validation:

```sh
bin/cpctl doctor \
  --config /usr/local/etc/bkcp/site.toml \
  --offline
```

Live dependency probes on FreeBSD:

```sh
bin/cpctl doctor \
  --config /usr/local/etc/bkcp/site.toml
```

`doctor` is read-only.

## 5. Initialize PostgreSQL state

Review embedded migrations:

```sh
bin/cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml \
  --dry-run \
  --json
```

Apply them:

```sh
bin/cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml
```

Check the inventory:

```sh
bin/cpctl status \
  --config /usr/local/etc/bkcp/site.toml
```

All V2 objects are created under the `bkcp` schema. Legacy V1 objects under `public` remain untouched.

## 6. Create a VM manifest

```sh
cp config/vms/freebsd-node.example.toml ./freebsd-node-01.toml
vi ./freebsd-node-01.toml
```

A manifest names a declared site image and pool and defines CPU, memory, disk, owner, power intent, profile, and SSH public-key path.

## 7. Produce a deterministic plan

```sh
bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --generation 1 \
  --json
```

The pure `plan` command does not consult or modify PostgreSQL. It emits normalized intent, digests, an idempotency key, and ordered future driver steps.

## Stop condition

There is no public `apply` command. Do not interpret a plan or persisted operation as proof that Kea, ZFS, PF, cloud-init, images, or `vm-bhyve` changed.

Continue with [CLI and Operations](CLI-and-Operations.md) for command and configuration details.