# Installation

Review interface names, networks, package versions, service paths, SSH access, database authentication, cloud-image policy, and the stable `CONTROL_PLANE_ID` before applying this configuration.

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

The default installation builds Stork `v2.5.0` from ISC's official source. This requires more build time and temporary disk space than the other package-based stages. To omit the Kea dashboard, add `STORK_ENABLE=no`.

Stork host editing requires a writable Kea hosts database. The standard FreeBSD Kea package has its `PGSQL` option disabled. When the required hook is missing, the dependency stage clones the FreeBSD ports tree and rebuilds `net/kea` automatically with `PGSQL` enabled. It uses `/usr/ports` when that path is absent or already contains a complete ports tree. If `/usr/ports` exists but is incomplete, it is preserved and a managed tree at `/var/cache/control-plane/ports` is used instead. The build is pinned to PostgreSQL 16, matching the server installed by this project. Allow extra time and disk space on the first run.

The Kea port uses Meson for its build and `rst2man` to generate manual pages. The installer determines the port's Python flavor and installs binary `meson` and matching `py*-docutils` packages before starting the ports build. This avoids building the legacy `py-setuptools` port currently flagged for CVE-2025-47273 through either dependency; the installer does not disable the ports vulnerability check.

Use a different existing ports tree by setting `KEA_PORTS_DIR`:

```sh
make install-dependencies KEA_PORTS_DIR=/path/to/ports
```

The dependency stage verifies `libdhcp_pgsql.so`, `libdhcp_host_cmds.so`, and `libdhcp_subnet_cmds.so` after the build and stops if any required library is still unavailable. Override the managed fallback location with `KEA_PORTS_FALLBACK_DIR` if necessary. This deployment does not load the mutually exclusive `cb_cmds` hook.

Run this control plane only on a FreeBSD release currently supported by the FreeBSD Security Team. Ports may warn or fail on an end-of-life release even when a particular build dependency can be supplied safely from packages; upgrade the host rather than disabling vulnerability checks.

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

Each stage can also be invoked separately:

```sh
make init-postgresql
make init-kea-host-db
make configure-services EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0 MGMT_ADDR=10.0.10.2 DNS_ADDR=10.0.20.1
make init-stork
make init-ipam IPAM_POOL=vm-lan IPAM_FIRST_HOST=10.0.20.10 IPAM_LAST_HOST=10.0.20.99
make init-vm VM_DATASET=zroot/vm LAN_IF=bridge0
make start-services
```

## Upgrade an existing installation

The integrity update introduces `db/003_mac_allocator.sql`, makes the PostgreSQL Kea hosts database the sole runtime reservation authority, and stops writing runtime reservations into `kea-dhcp4.conf`.

Before upgrading:

```sh
install -d -m 0700 /root/control-plane-upgrade
cp -p /usr/local/etc/kea/kea-dhcp4.conf \
  /root/control-plane-upgrade/kea-dhcp4.conf.before
sudo -u postgres pg_dump -Fc inventory \
  > /root/control-plane-upgrade/inventory.dump
sudo -u postgres pg_dump -Fc kea_hosts \
  > /root/control-plane-upgrade/kea-hosts.dump
```

Apply the inventory schema migration:

```sh
sh scripts/init_postgresql.sh
```

Confirm the allocator is present:

```sh
sudo -u postgres psql -d inventory -c '\df allocate_mac'
```

Re-render service configuration with the same interface, database, and address values used by the installation. When the PostgreSQL hosts backend is enabled, the renderer clears static subnet reservation arrays so they cannot shadow database reservations.

```sh
make configure-services \
  EXT_IF=igb0 \
  MGMT_IF=vlan10 \
  LAN_IF=bridge0 \
  MGMT_ADDR=10.0.10.2 \
  DNS_ADDR=10.0.20.1 \
  KEA_HOST_DB_NAME=kea_hosts \
  KEA_HOST_DB_USER=kea_hosts
```

Validate the rendered authority model before restarting services:

```sh
jq -e '
  .Dhcp4["hosts-databases"]
  | any(.type == "postgresql")
' /usr/local/etc/kea/kea-dhcp4.conf

jq -e '
  all(.Dhcp4.subnet4[]; (.reservations // []) | length == 0)
' /usr/local/etc/kea/kea-dhcp4.conf

kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
```

Then restart through the repository startup path and run host validation:

```sh
sh scripts/start_services.sh
make validate-freebsd
```

Before provisioning another production VM, verify one existing reservation through the authenticated Control Agent and complete one disposable provision/deprovision cycle. Preserve the old configuration and database dumps until that cycle succeeds.

## Cloud-image preparation

The default FreeBSD image includes cloud-init and uses the NoCloud datasource. The guest must support reading a CD-ROM labelled `cidata`.

Pre-fetch and verify the image before the first provisioning run:

```sh
make fetch-cloud-image
```

By default the fetcher downloads `CHECKSUM.SHA256` from the same release directory as the compressed image. A production site can pin the compressed digest explicitly:

```sh
sudo make fetch-cloud-image \
  FREEBSD_CLOUD_IMAGE_URL='https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz' \
  FREEBSD_CLOUD_IMAGE_SHA256='REPLACE_WITH_REVIEWED_SHA256'
```

Alternatively, override only the checksum manifest location:

```sh
sudo make fetch-cloud-image \
  FREEBSD_CLOUD_IMAGE_CHECKSUM_URL='https://example.invalid/approved/CHECKSUM.SHA256'
```

The default cache files are:

```text
/var/cache/control-plane/freebsd-cloud.raw
/var/cache/control-plane/freebsd-cloud.raw.verified
```

The marker records the source URL, compressed digest, and raw digest. The raw cache is reused only when the marker matches and the raw digest verifies. A corrupt or stale cache is replaced through a temporary file and atomic rename.

Keep the trusted management public key on the host:

```sh
install -d -m 0700 /root/.ssh
install -m 0600 /path/to/id_ed25519.pub /root/.ssh/bhyve-admin.pub
```

The provisioner rejects non-Ed25519 public keys.

The vm-bhyve template attaches `seed.iso` as an `ahci-cd` device. The provisioner creates that ISO inside each guest directory before first boot. The repository template and provisioner both enforce vm-bhyve's native `bhyveload` loader for FreeBSD guests.

## Stable control-plane identity

MAC candidates are derived from a stable control-plane namespace and VM name, then checked transactionally against active inventory. Set the same `CONTROL_PLANE_ID` on hosts that share one inventory database, and use a different value for independent inventories.

```sh
CONTROL_PLANE_ID=softcloud-lab-01
export CONTROL_PLANE_ID
```

Record this value in site configuration management. Changing it does not rewrite existing MAC addresses, but it changes candidates allocated for future guests.

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
Stork dashboard     MGMT_ADDR:8080 from management and VM LAN
Stork agent         127.0.0.1:8081
Stork Kea exporter  127.0.0.1:9547
Prometheus          127.0.0.1:9090
node_exporter       127.0.0.1:9100
postgres_exporter   127.0.0.1:9187
Kea Control Agent   127.0.0.1:8000 with HTTP Basic authentication
```

Verify the API without exposing credentials in documentation or logs:

```sh
KEA_API_USER=$(sed -n '1p' /usr/local/etc/kea/kea-api-user)
KEA_API_PASSWORD=$(sed -n '1p' /usr/local/etc/kea/kea-api-password)

curl -fsS \
  --user "${KEA_API_USER}:${KEA_API_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d '{"command":"status-get"}' \
  http://127.0.0.1:8000/ | jq .
```

## Finish Stork enrollment

Browse to `http://MGMT_ADDR:8080` from either the management network or the VM LAN. Keeping one canonical Stork address prevents generated agent installers from advertising a wildcard listener. The first login is `admin` / `admin`; Stork immediately requires a password change. Then open **Services -> Machines -> Unauthorized**, compare the displayed agent token with `/var/lib/stork-agent/tokens/agent-token.txt`, and authorize the local Kea host.

The Stork agent runs on the host rather than in a separate jail because it must inspect the Kea process and configuration. Its control listener and Prometheus exporter remain loopback-only. The UI is plain HTTP initially; terminate TLS at Stork or an authenticated management reverse proxy before using it across an untrusted network.

The installer already installs the native FreeBSD agent and its `stork_agent` rc service. Do not use `/stork-install-agent.sh` for this local host; that endpoint supports remote Linux agents distributed as `.deb`, `.rpm`, or `.apk` packages. By default, the installer downloads a pinned, SHA-256-verified package of each format from ISC Cloudsmith into `/usr/local/share/stork/www/assets/pkgs`, making the endpoint immediately usable.

Stork can expose only one package of each format, so all remote agents served by one control plane must use the selected CPU architecture. The default is inferred from the FreeBSD host. Override it with `STORK_AGENT_PACKAGE_ARCH=amd64` or `STORK_AGENT_PACKAGE_ARCH=arm64`. Run `make install-stork-agent-packages` to download or repair the package set without rebuilding Stork. Set `STORK_AGENT_PACKAGES_ENABLE=no` only when package distribution through the endpoint is intentionally disabled.
