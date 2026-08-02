# Installation

Run this project only on a FreeBSD release supported by the FreeBSD Security Team. Review interface names, addresses, storage, SSH access, database authentication, image policy, and `CONTROL_PLANE_ID` before applying changes.

## Install

Keep a working root console open and verify a second key-based SSH session first.

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

The installer refuses to run unless it is root on FreeBSD, the three interfaces exist, trusted SSH is confirmed, and shell syntax validation passes.

It then installs dependencies and configures:

- SSH hardening and PF;
- PostgreSQL inventory, IPAM, Kea hosts, and Stork databases;
- Kea DHCP4 and authenticated loopback Control Agent;
- Unbound DNS;
- vm-bhyve and ZFS storage;
- Stork, Prometheus, Loki, Grafana, and exporters.

The standard FreeBSD Kea package normally lacks PostgreSQL host support. When required, the dependency stage rebuilds `net/kea` with `PGSQL` enabled and verifies the PostgreSQL, host-command, and subnet-command hooks.

To omit Stork, export the option before running the standard install command:

```sh
export STORK_ENABLE=no
```

To use an existing ports tree:

```sh
make install-dependencies KEA_PORTS_DIR=/path/to/ports
```

To configure PostgreSQL metrics, export a DSN appropriate for the site's authentication policy before running the standard install command:

```sh
export POSTGRES_EXPORTER_DSN='postgresql://prometheus:REPLACE@127.0.0.1:5432/inventory?sslmode=disable'
```

The generated exporter configuration is permission-restricted. Prefer peer authentication, a password file, or certificates for long-term use.

## Run individual stages

The top-level install is idempotent. Stages can also be run separately:

```sh
make install-dependencies
make configure-host
make init-postgresql
make init-kea-host-db
make configure-services
make init-stork
make init-ipam
make init-vm
make start-services
make validate-freebsd
```

Pass the same interface, address, database, and storage values used during installation whenever rerunning a stage.

## Upgrade an existing installation

The integrity migration adds the transactional MAC allocator and makes the PostgreSQL Kea hosts database the only runtime reservation authority.

Back up the affected state:

```sh
install -d -m 0700 /root/control-plane-upgrade
cp -p /usr/local/etc/kea/kea-dhcp4.conf \
  /root/control-plane-upgrade/kea-dhcp4.conf.before
sudo -u postgres pg_dump -Fc inventory \
  > /root/control-plane-upgrade/inventory.dump
sudo -u postgres pg_dump -Fc kea_hosts \
  > /root/control-plane-upgrade/kea-hosts.dump
```

Apply the inventory migration:

```sh
sh scripts/init_postgresql.sh
sudo -u postgres psql -d inventory -c '\df allocate_mac'
```

Re-render service configuration using the current site values:

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

Confirm that PostgreSQL is configured and inline reservations are empty:

```sh
jq -e '.Dhcp4["hosts-databases"] | any(.type == "postgresql")' \
  /usr/local/etc/kea/kea-dhcp4.conf

jq -e 'all(.Dhcp4.subnet4[]; (.reservations // []) | length == 0)' \
  /usr/local/etc/kea/kea-dhcp4.conf

kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
sh scripts/start_services.sh
make validate-freebsd
```

Keep the backups until one disposable VM has been provisioned and deprovisioned successfully.

## Cloud image policy

Pre-fetch and verify the default FreeBSD cloud image:

```sh
make fetch-cloud-image
```

The fetcher verifies the compressed image, records the raw-image digest, and reuses the cache only when its verification marker still matches.

Default files:

```text
/var/cache/control-plane/freebsd-cloud.raw
/var/cache/control-plane/freebsd-cloud.raw.verified
```

For stronger provenance, pin a reviewed compressed-image digest:

```sh
sudo make fetch-cloud-image \
  FREEBSD_CLOUD_IMAGE_URL='https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz' \
  FREEBSD_CLOUD_IMAGE_SHA256='REPLACE_WITH_REVIEWED_SHA256'
```

The guest image must include cloud-init with NoCloud support and must read a CD-ROM labelled `cidata`.

## Stable control-plane identity

MAC candidates are derived from the VM name and a stable namespace, then checked transactionally against active inventory.

```sh
export CONTROL_PLANE_ID=softcloud-lab-01
```

Use the same value for hosts sharing one inventory database and a different value for independent inventories. Record it in site configuration management. Changing it affects only future allocations.

## Validate

```sh
make validate-freebsd
sockstat -4 -6 -l
service blacklistd status
vm list
```

Expected listeners:

```text
Unbound DNS         10.0.20.1:53 TCP/UDP
Grafana             MGMT_ADDR:3000
Stork dashboard     MGMT_ADDR:8080
Stork agent         127.0.0.1:8081
Stork Kea exporter  127.0.0.1:9547
Prometheus          127.0.0.1:9090
node_exporter       127.0.0.1:9100
postgres_exporter   127.0.0.1:9187
Kea Control Agent   127.0.0.1:8000 with HTTP Basic authentication
```

Verify the Kea API locally:

```sh
KEA_API_USER=$(sed -n '1p' /usr/local/etc/kea/kea-api-user)
KEA_API_PASSWORD=$(sed -n '1p' /usr/local/etc/kea/kea-api-password)

curl -fsS \
  --user "${KEA_API_USER}:${KEA_API_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d '{"command":"status-get"}' \
  http://127.0.0.1:8000/ | jq .
```

`curl --user` exposes the expanded credential to local process inspection. Run this only on the trusted host or use a protected curl configuration file.

## Finish Stork enrollment

Open `http://MGMT_ADDR:8080` from a trusted subnet. Sign in with `admin` / `admin`, change the password immediately, then authorize the pending local agent under **Services -> Machines -> Unauthorized** after comparing its token with:

```text
/var/lib/stork-agent/tokens/agent-token.txt
```

The native FreeBSD agent runs on the Kea host because it must inspect the local Kea process. Its listener and exporter remain loopback-only.

The `/stork-install-agent.sh` endpoint is for remote Linux agents. Repair its pinned package set with:

```sh
make install-stork-agent-packages STORK_AGENT_PACKAGE_ARCH=amd64
# or: STORK_AGENT_PACKAGE_ARCH=arm64
```

Use TLS directly or an authenticated reverse proxy before exposing Grafana or Stork outside trusted networks.
