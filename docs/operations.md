# Operations

## Provision a VM

The provisioner creates a NoCloud seed ISO containing the VM identity, local hostname, management user, and trusted Ed25519 SSH public key. Supply the key through a file where possible so it does not enter shell history.

Set `CONTROL_PLANE_ID` to a stable identifier shared by the hosts that participate in one control-plane inventory. Do not derive it from a transient hostname. When omitted, the provisioner falls back to `/etc/hostid` and then the current hostname.

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

For automation, `SSH_AUTHORIZED_KEY` may contain the complete public-key line directly. A site can pin the compressed cloud-image digest with `FREEBSD_CLOUD_IMAGE_SHA256`; otherwise the fetcher resolves the release `CHECKSUM.SHA256` file.

The operation succeeds only after:

1. PostgreSQL confirms that the name has no non-archived inventory row;
2. vm-bhyve confirms that no guest already uses the name and creates the guest definition and zvol;
3. the FreeBSD cloud image is downloaded when necessary, checksum-verified, decompressed, and recorded with a raw-cache verification marker;
4. the verified raw image is written to the guest zvol;
5. one PostgreSQL transaction allocates the IP address and collision-checked MAC address and inserts the `provisioning` inventory row;
6. the allocated MAC is persisted in the vm-bhyve guest configuration;
7. a `cidata` NoCloud seed ISO is created as `seed.iso` in the guest directory;
8. Kea accepts an authenticated `reservation-add` directed explicitly to the PostgreSQL hosts database;
9. the VM starts; and
10. the inserted inventory row is marked `running` by UUID.

Earlier failures trigger compensating cleanup of temporary seed inputs, Kea reservations and leases, PostgreSQL inventory/IPAM state, and vm-bhyve state.

An existing active name is never replaced automatically. Inspect it and, when removal is intended, run `scripts/deprovision_vm.sh` before retrying provisioning. Deprovisioning also completes when the Kea reservation or vm-bhyve guest is already absent, which permits cleanup of a stale inventory row. The provisioner reports stale inventory explicitly when PostgreSQL has an active row but vm-bhyve has no matching guest.

Finalization and compensating cleanup use the UUID of the newly inserted inventory row so archived rows that previously used the same VM name remain archived and are never modified by a new provisioning run.

The guest image must include cloud-init with the NoCloud datasource enabled. The selected vm-bhyve template must attach `seed.iso` as a CD-ROM. The provisioner enforces `bhyveload` in every newly created guest configuration before first boot, even if the installed vm-bhyve template is stale.

To migrate an existing `uefi` or `uefi-csm` guest through a guarded stop/change/start cycle:

```sh
sudo sh scripts/migrate_vm_to_bhyveload.sh db-node-03
```

The migration restores the original configuration and restarts the previous loader if changing the loader or restarting the VM fails.

## Provision a FreeBSD WireGuard and jail node

Provision a `bhyveload` FreeBSD VM prepared with WireGuard tooling and native FreeBSD jails:

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  VM_OWNER=admin \
  CLOUD_INIT_USER=admin \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_freebsd_jail_node.sh jail-node-01
```

Cloud-init installs `wireguard-tools`, persists and loads `if_wg`, enables the base-system jail service, and creates `/usr/local/jails`, `/etc/jail.conf.d`, and `/usr/local/etc/wireguard`. It does not generate WireGuard keys, invent peer addresses or routes, or create a jail. Supply those definitions separately.

After the guest boots, verify completion inside the guest with:

```sh
sudo cloud-init status --wait
test -f /var/db/freebsd-jail-node-ready
wg --version
sysrc jail_enable
```

Provision the three-node topology `jail-node-01` through `jail-node-03`:

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  VM_OWNER=admin \
  CLOUD_INIT_USER=admin \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_freebsd_jail_cluster.sh
```

The host keeps `bridge0` at MTU 1496 and vm-bhyve switch `public` uses that bridge. Kea advertises MTU 1496 to DHCP clients. vm-bhyve assigns tap interface numbers and process IDs at runtime; do not encode `tap0`-`tap2` or specific PIDs into automation.

## Deprovision a VM

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  sh scripts/deprovision_vm.sh db-node-01
```

Or use the Make target:

```sh
sudo make deprovision-vm VM_NAME=db-node-01
```

The command authenticates to Kea, deletes the reservation from the PostgreSQL hosts backend, attempts to delete the active lease, destroys the guest when present, archives the active inventory row by UUID, and releases the address. `rollback_vm.sh` remains the underlying transactional implementation.

## Inspect state

```sh
vm list
jls
container list 2>/dev/null || true
sudo -u postgres psql -d inventory -c 'TABLE vms;'
sudo -u postgres psql -d inventory -c 'TABLE ipam_leases;'
pfctl -sr
pfctl -a 'blacklistd/*' -sr
sockstat -4 -6 -l
service unbound status
drill @10.0.20.1 freebsd.org
```

Inspect the reservation backend through the authenticated loopback API. Replace subnet ID `1` when the selected pool uses another Kea subnet:

```sh
KEA_API_USER=$(sed -n '1p' /usr/local/etc/kea/kea-api-user)
KEA_API_PASSWORD=$(sed -n '1p' /usr/local/etc/kea/kea-api-password)

payload=$(jq -n '{
  command:"reservation-get-all",
  service:["dhcp4"],
  arguments:{
    "operation-target":"database",
    "subnet-id":1
  }
}')

curl -fsS \
  --user "${KEA_API_USER}:${KEA_API_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d "$payload" \
  http://127.0.0.1:8000/ | jq .
```

Do not place the password directly in shell history. The command substitution above keeps it out of the command line, but it is still present in the process environment of the shell and in memory while the request runs.

## Service management

Manage control-plane service containers and native services:

```sh
sh scripts/start_services.sh
container list
jls
jexec postgres psql -U postgres -d inventory
jexec kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
service stork_server status
service stork_agent status
service unbound status
```

The native FreeBSD agent is installed and registered directly; `/stork-install-agent.sh` distributes the pinned `.deb`, `.rpm`, or `.apk` package to remote Linux machines. Repair the served package set with `make install-stork-agent-packages STORK_AGENT_PACKAGE_ARCH=amd64` or `arm64`.

The Stork dashboard is at `http://MGMT_ADDR:8080` from both management and the VM LAN. Its database and the Kea hosts database are separate from `inventory`. Back them up with:

```sh
sudo -u postgres pg_dump -Fc stork > stork.dump
sudo -u postgres pg_dump -Fc kea_hosts > kea-hosts.dump
```

## Failure handling and reconciliation

If provisioning is interrupted after an external side effect, inspect every state domain before retrying:

```sh
VM_NAME=db-node-01
vm info "$VM_NAME" || true

sudo -u postgres psql -d inventory -x -c \
  "SELECT v.*, p.kea_subnet_id
     FROM vms v
     LEFT JOIN ipam_pools p ON p.id = v.pool_id
    WHERE v.name = '${VM_NAME}'
    ORDER BY v.created_at DESC;"

sudo -u postgres psql -d inventory -x -c \
  "SELECT l.*
     FROM ipam_leases l
     JOIN vms v ON v.pool_id = l.pool_id AND v.ip_address = l.ip_address
    WHERE v.name = '${VM_NAME}'
    ORDER BY l.allocated_at DESC;"

jls
zfs list -r zroot/vm | grep "$VM_NAME" || true
```

Use the authenticated reservation query from the previous section with the inventory row's `kea_subnet_id`. Compare the returned MAC and address with the active inventory row and vm-bhyve configuration.

Do not reuse an IP address until the active inventory row, IPAM lease, Kea reservation, active DHCP lease, vm-bhyve guest, and guest zvol are reconciled. For a normal stale-state cleanup, prefer:

```sh
sudo PGDATABASE=inventory PGUSER=postgres \
  sh scripts/deprovision_vm.sh "$VM_NAME"
```

A host crash can occur before shell traps run. Periodic reconciliation should therefore report, rather than silently repair, at least these mismatches:

- active inventory row without a vm-bhyve guest;
- vm-bhyve guest without an active inventory row;
- active inventory address without a PostgreSQL-backed Kea reservation;
- Kea reservation without an active inventory row;
- released IPAM address still present in an active reservation or lease;
- duplicate control-plane namespaces used by independent inventories.

## Cloud-image cache maintenance

The default cache consists of:

```text
/var/cache/control-plane/freebsd-cloud.raw
/var/cache/control-plane/freebsd-cloud.raw.verified
```

Validate or repair it by rerunning:

```sh
sudo make fetch-cloud-image
```

The fetcher reuses the cache only when the marker source and raw digest match. To rotate to a new image, update the URL and optional pinned digest together, run `make fetch-cloud-image`, and provision a disposable guest before adopting it for production workloads.

Do not manually edit the `.verified` marker. Removing both files is safe when no provisioning process is using the cache; the next fetch recreates them atomically.

## Backups

Back up:

- `/etc/rc.conf`, `/etc/pf.conf`, `/etc/jail.conf`, `/etc/ssh`, and `/etc/blacklistd.conf`;
- `/usr/local/etc/kea`, including API and hosts-database credential files;
- `/usr/local/etc/unbound`;
- `/usr/local/etc/stork`, `/var/lib/stork-agent`, and the Stork PostgreSQL database;
- the Kea PostgreSQL hosts database;
- PostgreSQL inventory and IPAM state using `pg_dump`;
- vm-bhyve templates and guest definitions;
- ZFS snapshots and replication targets;
- SSH host keys and future SSH CA trust anchors;
- site-controlled image URLs, pinned digests, and `CONTROL_PLANE_ID` values.

The cloud-image cache itself is reproducible and need not be backed up when the source URL and digest policy are recorded.

## Change control

Before applying changes:

```sh
make lint
make test
make validate-freebsd
pfctl -nf /etc/pf.conf
```

After service or schema changes, verify the authenticated Kea API, PostgreSQL inventory, reservation backend, and one disposable guest lifecycle before production provisioning.
