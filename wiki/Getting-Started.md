# Getting Started

## Prerequisites

The portable development workflow requires the Go version declared in `go.mod` and GNU-compatible `make`.

A target deployment also requires:

- FreeBSD with hardware virtualization enabled;
- ZFS and a dataset reserved for VM storage;
- `vm-bhyve`;
- PostgreSQL 16;
- Kea DHCP4 and its Control Agent for future reservation execution;
- PF configuration capable of loading a dedicated `bkcp` anchor.

The current implementation can be built and tested on non-FreeBSD systems. Live host validation and future infrastructure drivers target FreeBSD.

## Clone, verify, and build

```sh
git clone https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
cd freebsd-bhyve-kea-control-plane
make verify
make build
```

The binary is written to `bin/cpctl`.

## Create the site configuration

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
```

Set a stable `control_plane_id`. Do not change it after state has been initialized because it participates in deterministic operation identity and per-resource locking.

Replace the example image checksum before any future image-fetch or apply capability is used. The all-zero digest is a validation sentinel, not a trusted image digest.

## Validate configuration and dependencies

Validate structure without contacting services:

```sh
bin/cpctl doctor \
  --config /usr/local/etc/bkcp/site.toml \
  --offline
```

Run live dependency probes on the FreeBSD control-plane host:

```sh
bin/cpctl doctor \
  --config /usr/local/etc/bkcp/site.toml
```

## Initialize PostgreSQL state

Review pending migrations first:

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

Inspect the empty state inventory:

```sh
bin/cpctl status \
  --config /usr/local/etc/bkcp/site.toml
```

## Create and inspect a VM manifest

Start with the checked-in example:

```sh
cp config/vms/freebsd-node.example.toml ./freebsd-node-01.toml
vi ./freebsd-node-01.toml
```

Generate a deterministic plan without changing the database or host:

```sh
bin/cpctl plan \
  --config /usr/local/etc/bkcp/site.toml \
  --file ./freebsd-node-01.toml \
  --generation 1 \
  --json
```

There is no public `apply` command yet. Plan output must be treated as a preview and execution contract only.

## Next reading

- [Configuration](Configuration.md)
- [CLI and Operations](CLI-and-Operations.md)
- [State and Migrations](State-and-Migrations.md)