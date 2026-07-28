# Installation

Review interface names, networks, package versions, service paths, and SSH access before applying this configuration.

## Guarded installation

The Makefile provides an end-to-end installer, but it refuses to run unless:

- the target is FreeBSD;
- the configured external, management, and VM bridge interfaces exist;
- the process runs as root;
- trusted key-based SSH access has been explicitly confirmed;
- all shell scripts pass syntax validation.

Keep the current root console open and verify a second SSH session using the trusted Ed25519 key before continuing.

```sh
make install \
  TRUSTED_SSH_READY=yes \
  EXT_IF=igb0 \
  MGMT_IF=vlan10 \
  LAN_IF=bridge0 \
  MGMT_ADDR=10.0.10.2 \
  DNS_ADDR=10.0.20.1 \
  VM_DATASET=zroot/vm
```

The default installation builds Stork `v2.5.0` from ISC’s official source. This requires more build time and temporary disk space than the other package-based stages. To omit the Kea dashboard, add `STORK_ENABLE=no`.

The installer does not attach the physical external interface directly to the VM switch. It creates a manual vm-bhyve switch backed by the existing `LAN_IF` bridge, preserving the intended network boundary.

To enable PostgreSQL metrics, provide the exporter DSN explicitly:

```sh
make install \
  TRUSTED_SSH_READY=yes \
  EXT_IF=igb0 \
  MGMT_IF=vlan10 \
  LAN_IF=bridge0 \
  MGMT_ADDR=10.0.10.2 \
  POSTGRES_EXPORTER_DSN='postgresql://prometheus:REPLACE@127.0.0.1:5432/inventory?sslmode=disable'
```

The DSN is written to `/etc/rc.conf.d/postgres_exporter` with restrictive permissions. Prefer a password file or peer-authenticated exporter design for long-term operation.

## Installation stages

The `install` target runs these idempotent stages in sequence:

```text
check-root
check-platform
check-trust
syntax
install-dependencies
configure-host
configure-services
init-postgresql
init-stork
init-ipam
init-vm
start-services
validate-freebsd
```

Each stage can also be invoked separately, for example:

```sh
make configure-services EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0 MGMT_ADDR=10.0.10.2 DNS_ADDR=10.0.20.1
make init-postgresql
make init-stork
make init-ipam IPAM_POOL=vm-lan IPAM_FIRST_HOST=10.0.20.10 IPAM_LAST_HOST=10.0.20.99
make init-vm VM_DATASET=zroot/vm LAN_IF=bridge0
make start-services
```

## Cloud image preparation

Use a guest image that includes cloud-init and has the NoCloud datasource enabled. The image must support reading a CD-ROM labelled `cidata`.

Keep the trusted management public key on the host:

```sh
install -d -m 0700 /root/.ssh
install -m 0600 /path/to/id_ed25519.pub /root/.ssh/bhyve-admin.pub
```

The provisioner rejects non-Ed25519 public keys.

The vm-bhyve template attaches `seed.iso` as an `ahci-cd` device. The provisioner creates that ISO inside each guest directory before first boot.

## Manual validation

```sh
make validate-freebsd
container list
sockstat -4 -6 -l
service blacklistd status
vm list
```

Expected exposure:

```text
BIND DNS           10.0.20.1:53 (TCP and UDP)
Grafana             MGMT_ADDR:3000
Stork dashboard     MGMT_ADDR:8080
Stork agent         127.0.0.1:8081
Stork Kea exporter  127.0.0.1:9547
Prometheus          127.0.0.1:9090
node_exporter       127.0.0.1:9100
postgres_exporter   127.0.0.1:9187
Kea Control Agent   127.0.0.1:8000
```

## Finish Stork enrollment

Browse to `http://MGMT_ADDR:8080`. The first login is `admin` / `admin`; Stork immediately requires a password change. Then open **Services → Machines → Unauthorized**, compare the displayed agent token with `/var/lib/stork-agent/tokens/agent-token.txt`, and authorize the local Kea host.

The Stork agent runs on the host rather than in a separate jail because it must inspect the Kea process and configuration. Its control listener and Prometheus exporter remain loopback-only. The UI is plain HTTP initially; terminate TLS at Stork or an authenticated management reverse proxy before using it across an untrusted network.
