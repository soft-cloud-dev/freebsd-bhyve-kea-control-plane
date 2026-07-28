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

Stork host editing requires a writable Kea hosts database. The standard FreeBSD Kea package has its `PGSQL` option disabled, so install `net/kea` 3.0 or newer from ports with PostgreSQL support before running the installer:

```sh
git clone --depth 1 https://git.FreeBSD.org/ports.git /usr/ports
cd /usr/ports/net/kea
make -DBATCH OPTIONS_SET=PGSQL install clean
```

If the binary package is already installed, rebuild it with the option enabled:

```sh
cd /usr/ports/net/kea
make -DBATCH OPTIONS_SET=PGSQL reinstall clean
```

The dependency stage verifies `libdhcp_pgsql.so`, `libdhcp_host_cmds.so`, and `libdhcp_subnet_cmds.so` and stops with a clear error when the required build is unavailable. This deployment does not load the mutually exclusive `cb_cmds` hook.

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
init-postgresql
init-kea-host-db
configure-services
init-stork
init-ipam
init-vm
start-services
validate-freebsd
```

Each stage can also be invoked separately, for example:

```sh
make init-postgresql
make init-kea-host-db
make configure-services EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0 MGMT_ADDR=10.0.10.2 DNS_ADDR=10.0.20.1
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
Unbound DNS         10.0.20.1:53 (TCP and UDP)
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

The installer already installs the native FreeBSD agent and its `stork_agent` rc service. Do not use `/stork-install-agent.sh` for this local host; that endpoint only supports remote Linux agents distributed as `.deb`, `.rpm`, or `.apk` packages. The repository creates `/usr/local/share/stork/www/assets/pkgs` so the endpoint fails cleanly when no Linux packages have been supplied. To enable it for remote Linux hosts, download version-matched agent packages from ISC Cloudsmith and place them in that directory with their original `isc-stork-agent` filenames.
