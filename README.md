# FreeBSD bhyve + Kea Control Plane

A FreeBSD-native control plane for ZFS-backed `vm-bhyve` guests, PostgreSQL inventory/IPAM, Kea DHCP reservations, Unbound DNS, PF isolation, Stork, Prometheus, Loki, and Grafana.

## Core model

```text
SSH / FreeIPA trust
        |
   FreeBSD host
        |
  +-----+-----------------------------+
  |                                   |
vm-bhyve + ZFS                  PostgreSQL
  |                        inventory/IPAM
  |                        Kea hosts DB
  |                        Stork DB
  +---------------+-------------------+
                  |
               Kea DHCP
                  |
               bridge0
                  |
               bhyve VMs
```

The main invariants are:

- PostgreSQL owns inventory and IP allocation state.
- The PostgreSQL Kea hosts database is the only writable reservation authority.
- MAC addresses are allocated transactionally from a stable `CONTROL_PLANE_ID` namespace.
- Cloud images are written to guests only after SHA-256 verification.
- Kea Control Agent, PostgreSQL, Prometheus, Loki, and exporters remain local or loopback-bound.
- PF defaults to deny and exposes each service only on its intended network.
- Provisioning failures trigger best-effort rollback; host crashes may still require reconciliation.

See [`docs/architecture.md`](docs/architecture.md) and [`docs/security-model.md`](docs/security-model.md).

## Install

Run on a supported FreeBSD release as root. Keep a working console and verify key-based SSH before applying host changes.

```sh
make install \
  TRUSTED_SSH_READY=yes \
  SSH_ADMIN_KEY_FILE=/root/.ssh/id_ed25519.pub \
  EXT_IF=igb0 \
  MGMT_IF=vlan10 \
  LAN_IF=bridge0 \
  MGMT_ADDR=10.0.10.2 \
  DNS_ADDR=10.0.20.1 \
  VM_DATASET=zroot/vm
```

The installer configures the host, databases, Kea, DNS, PF, observability, Stork, IPAM, and vm-bhyve. The standard FreeBSD Kea package normally lacks PostgreSQL support, so the dependency stage rebuilds `net/kea` when required.

Full installation, upgrade, image, and Stork instructions are in [`docs/installation.md`](docs/installation.md).

## Provision a VM

Set one stable `CONTROL_PLANE_ID` for every host sharing the same inventory database.

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  VM_OWNER=admin \
  CLOUD_INIT_USER=admin \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_vm.sh db-node-01 freebsd
```

Provisioning verifies the image, creates the guest, allocates IP and MAC state in one PostgreSQL transaction, adds a database-backed Kea reservation, starts the VM, and marks the inventory row `running`.

Deprovision:

```sh
sudo make deprovision-vm VM_NAME=db-node-01
```

## Provision three FreeBSD nodes

One command provisions `freebsd-node-01` through `freebsd-node-03`, waits for cloud-init readiness over SSH, writes a TSV inventory, and bootstraps the local `kubectl` client:

```sh
sudo make cluster-up \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE=/root/.ssh/id_ed25519.pub \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519 \
  KUBECONFIG_SOURCE=/root/kubeconfig
```

`KUBECONFIG_SOURCE` is optional. When supplied, it is installed as `/root/.kube/config` and verified with `kubectl cluster-info`. The FreeBSD guests are prepared for native jails and WireGuard; this workflow does not install `kubelet` or `kubeadm` on them.

```sh
sudo make cluster-status
sudo make cluster-down
```

Operational commands and failure recovery are in [`docs/operations.md`](docs/operations.md).

## Validate

```sh
make lint
make test
make validate-freebsd
```

CI is split into portable validation, FreeBSD Kea integration, and a manually triggered bare-metal bhyve workflow. See [`docs/testing.md`](docs/testing.md).

## Documentation

- [`docs/installation.md`](docs/installation.md): install, upgrade, image policy, Stork enrollment
- [`docs/operations.md`](docs/operations.md): provision, inspect, recover, back up
- [`docs/architecture.md`](docs/architecture.md): component authority and provisioning flow
- [`docs/security-model.md`](docs/security-model.md): trust boundaries and residual risks
- [`docs/observability.md`](docs/observability.md): metrics, logs, dashboards, alerts
- [`docs/testing.md`](docs/testing.md): CI and bare-metal validation

## Boundaries

- `vm-bhyve` and ZFS administration require root privileges.
- Shell rollback is not a crash-safe distributed transaction.
- The default image checksum comes from the same HTTPS release origin unless a digest is independently pinned.
- Grafana and Stork use HTTP initially; production TLS is site-specific.
- Package names, hook paths, and rc.d behavior vary across FreeBSD releases.

## License

BSD-3-Clause. See [`LICENSE`](LICENSE).
