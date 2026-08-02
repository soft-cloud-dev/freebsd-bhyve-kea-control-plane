# Bare-Metal Three-Node Bootstrap

This runbook builds one FreeBSD bare-metal control-plane host and three FreeBSD `vm-bhyve` guests.

It deliberately separates the frozen executable V1 shell stack from the canonical V2 control plane.

## Target topology

```text
                         management VLAN 10
Internet / upstream -- igb0 -- vlan10: 10.0.10.2/24
                         |
                         | PF routing/NAT
                         |
                    bridge0: 10.0.20.1/24
                         |
                  vm-bhyve switch "public"
                    /          |          \
       freebsd-node-01  freebsd-node-02  freebsd-node-03
```

The bare-metal host runs:

- ZFS and `vm-bhyve`;
- PostgreSQL inventory/IPAM and V2 state;
- Kea DHCP4 and Kea Control Agent;
- Unbound DNS;
- PF routing and isolation;
- Prometheus, Loki, Grafana, and exporters;
- optionally Stork.

The guests are ordinary FreeBSD VMs prepared for native jails and WireGuard. The V1 cloud-init profile does not create a Kubernetes cluster, WireGuard mesh, distributed database, or HA control plane.

## V1/V2 execution boundary

V2 is currently stateful but non-executing. It validates configuration, migrates the `bkcp` schema, inspects state, and generates deterministic plans. It does not allocate addresses, promote images, generate cloud-init, modify Kea, create ZFS storage, or operate `vm-bhyve`.

The supported bootstrap sequence is therefore:

1. Use `legacy/v1-shell` to install and mutate the bare-metal host.
2. Use V1 to provision the three VMs.
3. Install V2 alongside V1 for validation, migrations, and planning.
4. Keep the VMs V1-managed until V2 import and adoption are implemented.

Do not copy V1 scripts into `main`. A V2 plan is an execution contract, not evidence that infrastructure changed.

## Release selection

As of August 2, 2026, FreeBSD 15.1-RELEASE is the newest production release. For this frozen V1 workflow, use FreeBSD 14.4-RELEASE for both host and guests because it is closer to the 14.x environment for which the scripts were written.

FreeBSD 14.4-RELEASE is supported through December 31, 2026. FreeBSD 14.3-RELEASE reached end of life on June 30, 2026, so override the V1 default image URL.

Use:

```text
FreeBSD-14.4-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz
```

Official references:

- https://www.freebsd.org/releases/
- https://www.freebsd.org/releases/14.4R/announce/
- https://www.freebsd.org/security/
- https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/amd64/Latest/

## Hardware baseline

Enable Intel VT-x/EPT or AMD-V/RVI in firmware. Keep IPMI, serial console, or a local keyboard attached throughout network, SSH, and PF configuration.

The default VM template gives each node:

- 2 vCPUs;
- 2 GiB RAM;
- 20 GiB sparse ZFS storage;
- one virtio network interface;
- one NoCloud seed ISO.

For three nodes, reserve at least 6 vCPUs, 6 GiB guest RAM, and 60 GiB nominal guest storage. A practical host baseline is 8 CPU threads, 16 GiB RAM, and at least 128 GiB usable ZFS capacity.

## Network plan

The example assumes:

```text
igb0       upstream trunk
vlan10     management network, 10.0.10.2/24
bridge0    isolated VM LAN, 10.0.20.1/24
```

The upstream switch port connected to `igb0` must carry VLAN 10 tagged.

The VM LAN does not require a physical bridge member. The host routes and NATs traffic between `bridge0` and the upstream interface through PF. Kea and Unbound serve the VM LAN.

The V1 top-level installer checks that `EXT_IF`, `MGMT_IF`, and `LAN_IF` already exist before the host setup stage. Create `vlan10` and `bridge0` temporarily before running `make install`; the installer persists them afterward.

## Repository layout

Use separate checkouts:

```text
/usr/local/src/bkcp-v1
/usr/local/src/bkcp-v2
```

- `bkcp-v1` is the temporary infrastructure writer.
- `bkcp-v2` is the canonical state, validation, and planning implementation.

## Phase 1: bare-metal preflight

Replace interface, gateway, hostname, and key paths before running this block from a local or IPMI console.

```sh
set -eu

HOSTNAME_FQDN=bhyve01.softcloud.dev
EXT_IF=igb0
MGMT_IF=vlan10
MGMT_VLAN=10
MGMT_ADDR=10.0.10.2
MGMT_PREFIX=24
MGMT_GW=10.0.10.1
LAN_IF=bridge0
LAN_ADDR=10.0.20.1
LAN_PREFIX=24
LAN_MTU=1496
VM_DATASET=zroot/vm
ADMIN_KEY=/root/bootstrap-admin.pub

test "$(id -u)" -eq 0
test -r "$ADMIN_KEY"

hostname "$HOSTNAME_FQDN"
sysrc hostname="$HOSTNAME_FQDN"

freebsd-update fetch install

env ASSUME_ALWAYS_YES=yes pkg bootstrap
pkg update
pkg install -y git ca_root_nss

sysrc ntpd_enable=YES
service ntpd restart 2>/dev/null || service ntpd start

kldload vmm
kldload if_vlan 2>/dev/null || true

grep -E 'VT-x|Features2' /var/run/dmesg.boot || true
sysctl hw.vmm.vmx.initialized 2>/dev/null || \
  sysctl hw.vmm.svm.features 2>/dev/null || true

ifconfig "$EXT_IF" up

ifconfig "$MGMT_IF" >/dev/null 2>&1 || ifconfig "$MGMT_IF" create
ifconfig "$MGMT_IF" vlan "$MGMT_VLAN" vlandev "$EXT_IF"
ifconfig "$MGMT_IF" inet "$MGMT_ADDR/$MGMT_PREFIX" mtu 1496 up

ifconfig "$LAN_IF" >/dev/null 2>&1 || ifconfig "$LAN_IF" create
ifconfig "$LAN_IF" inet "$LAN_ADDR/$LAN_PREFIX" mtu "$LAN_MTU" up

route -n get default >/dev/null 2>&1 || route add default "$MGMT_GW"

zpool status
ifconfig "$EXT_IF"
ifconfig "$MGMT_IF"
ifconfig "$LAN_IF"
```

## Phase 2: clone and install V1

The installer configures SSH hardening, PF, PostgreSQL, Kea, Unbound, ZFS, `vm-bhyve`, and observability. Start with Stork disabled; it is not required to validate DHCP and VM provisioning.

```sh
set -eu

REPOSITORY=https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
V1_DIR=/usr/local/src/bkcp-v1
V2_DIR=/usr/local/src/bkcp-v2
ADMIN_KEY=/root/bootstrap-admin.pub

test -d "$V1_DIR/.git" || \
  git clone --branch legacy/v1-shell --single-branch "$REPOSITORY" "$V1_DIR"

test -d "$V2_DIR/.git" || \
  git clone --branch main --single-branch "$REPOSITORY" "$V2_DIR"

cd "$V1_DIR"
make lint

make install \
  TRUSTED_SSH_READY=yes \
  STORK_ENABLE=no \
  MGMT_USER=admin \
  SSH_ADMIN_KEY_FILE="$ADMIN_KEY" \
  EXT_IF=igb0 \
  MGMT_IF=vlan10 \
  LAN_IF=bridge0 \
  LAN_MTU=1496 \
  MGMT_ADDR=10.0.10.2 \
  MGMT_NET=10.0.10.0/24 \
  LAN_NET=10.0.20.0/24 \
  DNS_ADDR=10.0.20.1 \
  VM_DATASET=zroot/vm \
  IPAM_POOL=vm-lan \
  IPAM_SUBNET=10.0.20.0/24 \
  IPAM_FIRST_HOST=10.0.20.10 \
  IPAM_LAST_HOST=10.0.20.99 \
  IPAM_VLAN=20 \
  KEA_SUBNET_ID=1

make validate-freebsd STORK_ENABLE=no

sockstat -4 -6 -l
vm switch list
vm list
zfs list -r zroot/vm
```

Keep the console open until a second key-based SSH session to `admin@10.0.10.2` succeeds.

Expected core listeners:

```text
Unbound DNS          10.0.20.1:53
Grafana              10.0.10.2:3000
Prometheus           127.0.0.1:9090
Loki                 127.0.0.1:3100
node_exporter        127.0.0.1:9100
postgres_exporter    127.0.0.1:9187
Kea Control Agent    127.0.0.1:8000
```

Validate PostgreSQL, Kea, ZFS, `vm-bhyve`, PF, DNS, and observability as separate authority domains.

## Phase 3: pin the cloud image

The V1 fetcher verifies the compressed image, decompresses it, records the raw-image digest, and reuses the cache only when the verification marker still matches.

The verified raw image is stored at:

```text
/var/cache/control-plane/freebsd-cloud.raw
```

Pin the checksum explicitly:

```sh
set -eu

V1_DIR=/usr/local/src/bkcp-v1
CONTROL_PLANE_ID=softcloud-lab-01
CLUSTER_KEY=/root/.ssh/freebsd-cluster
IMAGE_URL=https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/amd64/Latest/FreeBSD-14.4-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz
CHECKSUM_URL=https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/amd64/Latest/CHECKSUM.SHA256
CHECKSUM_FILE=/root/FreeBSD-14.4-CHECKSUM.SHA256
IMAGE_NAME=${IMAGE_URL##*/}

install -d -m 0700 /root/.ssh

if [ ! -f "$CLUSTER_KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$CLUSTER_KEY"
fi

fetch -o "$CHECKSUM_FILE" "$CHECKSUM_URL"

IMAGE_SHA256=$(
    awk -v image="$IMAGE_NAME" \
      '$1 == "SHA256" && $2 == "(" image ")" && $3 == "=" { print $4; exit }' \
      "$CHECKSUM_FILE"
)

test "${#IMAGE_SHA256}" -eq 64

cd "$V1_DIR"

make fetch-cloud-image \
  FREEBSD_CLOUD_IMAGE_URL="$IMAGE_URL" \
  FREEBSD_CLOUD_IMAGE_SHA256="$IMAGE_SHA256" \
  FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="$CHECKSUM_URL"
```

## Phase 4: review VM sizing

The active template is normally located below the ZFS dataset mount point:

```text
/zroot/vm/.templates/freebsd.conf
```

Discover the actual mount point with:

```sh
zfs get -H -o value mountpoint zroot/vm
```

Edit the template before creating the first node when the defaults are insufficient. For example:

```text
cpu="2"
memory="4G"
disk0_size="40G"
```

Changing `disk0_size` after guest creation does not resize an existing zvol automatically.

## Phase 5: provision three nodes

Disable kubectl bootstrap. The V1 cluster workflow installs kubectl only as a client for a separate Kubernetes control plane; these FreeBSD guests are not configured as kubelet workers.

```sh
set -eu

V1_DIR=/usr/local/src/bkcp-v1
CONTROL_PLANE_ID=softcloud-lab-01
CLUSTER_KEY=/root/.ssh/freebsd-cluster
IMAGE_URL=https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/amd64/Latest/FreeBSD-14.4-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz
CHECKSUM_URL=https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/amd64/Latest/CHECKSUM.SHA256
IMAGE_SHA256=$(awk -v image="${IMAGE_URL##*/}" \
  '$1 == "SHA256" && $2 == "(" image ")" && $3 == "=" { print $4; exit }' \
  /root/FreeBSD-14.4-CHECKSUM.SHA256)

cd "$V1_DIR"

make cluster-up \
  KUBECTL_BOOTSTRAP=no \
  CONTROL_PLANE_ID="$CONTROL_PLANE_ID" \
  CLUSTER_NODE_PREFIX=freebsd-node \
  CLUSTER_NODE_COUNT=3 \
  CLUSTER_BOOT_TIMEOUT=600 \
  CLUSTER_POLL_INTERVAL=5 \
  VM_OWNER=admin \
  CLOUD_INIT_USER=admin \
  IPAM_POOL=vm-lan \
  SSH_PUBLIC_KEY_FILE="${CLUSTER_KEY}.pub" \
  SSH_PRIVATE_KEY_FILE="$CLUSTER_KEY" \
  FREEBSD_CLOUD_IMAGE_URL="$IMAGE_URL" \
  FREEBSD_CLOUD_IMAGE_SHA256="$IMAGE_SHA256" \
  FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="$CHECKSUM_URL"
```

For each node, V1:

1. creates a `vm-bhyve` guest;
2. enforces `bhyveload`;
3. writes the verified raw image to the guest zvol;
4. transactionally allocates IP and MAC state in PostgreSQL;
5. writes the MAC to the guest configuration;
6. creates a NoCloud `cidata` seed ISO;
7. adds a PostgreSQL-backed Kea reservation;
8. starts the guest;
9. marks the inventory row as running.

The wrapper waits for `/var/db/freebsd-jail-node-ready` over SSH and writes:

```text
/var/db/freebsd-bhyve-kea-control-plane/clusters/freebsd-node.tsv
```

Shell rollback is best-effort rather than crash-safe. Interrupted runs may require manual reconciliation.

## Phase 6: validate the nodes

Verify four views:

1. `vm list` — runtime state.
2. `make cluster-status` — V1 inventory state.
3. Kea reservations — DHCP authority.
4. SSH/cloud-init state inside each guest.

```sh
set -eu

V1_DIR=/usr/local/src/bkcp-v1
CLUSTER_KEY=/root/.ssh/freebsd-cluster
INVENTORY=/var/db/freebsd-bhyve-kea-control-plane/clusters/freebsd-node.tsv

cd "$V1_DIR"

make cluster-status \
  CLUSTER_NODE_PREFIX=freebsd-node \
  CLUSTER_NODE_COUNT=3

vm list
cat "$INVENTORY"

awk 'NR > 1 { print $1, $2 }' "$INVENTORY" |
while read -r name ip
do
    printf '%s %s\n' "$name" "$ip"
    ssh \
      -i "$CLUSTER_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      "admin@$ip" \
      'uname -a; test -f /var/db/freebsd-jail-node-ready; sysrc -n jail_enable; wg --version'
done
```

Inside each guest, verify:

- the expected FreeBSD release;
- `jail_enable=YES`;
- `wireguard-tools` installed;
- `if_wg` loadable;
- readiness marker present;
- default route through `10.0.20.1`;
- DNS through `10.0.20.1`;
- outbound connectivity.

This produces three prepared FreeBSD jail/WireGuard nodes. Creating an actual distributed service remains a separate workload-specific step.

## Phase 7: initialize V2 alongside V1

Create:

```text
/usr/local/etc/bkcp/site.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-01.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-02.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-03.toml
```

The V2 site configuration must describe the same stable control-plane ID, interfaces, bridge, ZFS dataset, PostgreSQL instance, Kea endpoint, pool, image, and verified digest.

```sh
set -eu

V2_DIR=/usr/local/src/bkcp-v2

cd "$V2_DIR"
git pull --ff-only
make verify
make build

install -m 0755 bin/cpctl /usr/local/sbin/cpctl
install -d -m 0750 /usr/local/etc/bkcp
install -d -m 0750 /usr/local/etc/bkcp/vms.d

test -f /usr/local/etc/bkcp/site.toml || \
  cp config/site.example.toml /usr/local/etc/bkcp/site.toml

cp config/vms/freebsd-node.example.toml \
  /usr/local/etc/bkcp/vms.d/freebsd-node-01.toml

sed 's/name = "freebsd-node-01"/name = "freebsd-node-02"/' \
  config/vms/freebsd-node.example.toml \
  > /usr/local/etc/bkcp/vms.d/freebsd-node-02.toml

sed 's/name = "freebsd-node-01"/name = "freebsd-node-03"/' \
  config/vms/freebsd-node.example.toml \
  > /usr/local/etc/bkcp/vms.d/freebsd-node-03.toml

cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml
cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml

for manifest in /usr/local/etc/bkcp/vms.d/*.toml
do
    cpctl plan \
      --config /usr/local/etc/bkcp/site.toml \
      --file "$manifest" \
      --generation 1 \
      --json
done
```

Stop at `plan`. V2 has no public `apply` or `adopt` command, so it must not claim ownership of the V1-created guests. `cpctl status` may remain empty until import and adoption are implemented.

## Back up the working installation

Preserve:

```text
PostgreSQL inventory database
PostgreSQL kea_hosts database
/usr/local/etc/kea
/usr/local/etc/pf.conf and included anchors
/usr/local/etc/unbound
/usr/local/etc/grafana
/usr/local/etc/prometheus.yml
/usr/local/etc/loki.yml
/usr/local/etc/promtail.yml
/zroot/vm
/usr/local/etc/bkcp
```

Take PostgreSQL-consistent dumps and a recursive ZFS snapshot before further experimentation.

## Remove the three V1-managed nodes

Use `cluster-down` only while the V1 inventory, Kea reservations, ZFS resources, and `vm-bhyve` guests remain mutually consistent.

```sh
set -eu

cd /usr/local/src/bkcp-v1

make cluster-down \
  CLUSTER_NODE_PREFIX=freebsd-node \
  CLUSTER_NODE_COUNT=3

make cluster-status \
  CLUSTER_NODE_PREFIX=freebsd-node \
  CLUSTER_NODE_COUNT=3

vm list
```

Do not run `cluster-down` after manually deleting inventory rows or guests. Reconcile the authoritative systems first.