# Operations

## Provision a VM

Use a stable `CONTROL_PLANE_ID` for every host sharing the same inventory database.

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

The provisioner:

1. rejects duplicate or stale active state;
2. verifies and writes the cloud image;
3. creates the guest and NoCloud seed;
4. allocates IP, MAC, and inventory state in PostgreSQL;
5. adds an authenticated database-backed Kea reservation;
6. starts the VM and marks the inventory row `running`.

Failures trigger best-effort cleanup. A host crash may still leave state requiring reconciliation.

The guest must use cloud-init with the NoCloud datasource. The provisioner enforces the native `bhyveload` loader before first boot.

For direct key input, `SSH_AUTHORIZED_KEY` may replace `SSH_PUBLIC_KEY_FILE`.

## Provision jail-ready guests

Single FreeBSD WireGuard and jail node:

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_freebsd_jail_node.sh jail-node-01
```

Three-node topology:

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_freebsd_jail_cluster.sh
```

The profile installs WireGuard tooling and enables native jails. It does not create keys, peers, routes, or jail definitions.

Inside a guest:

```sh
sudo cloud-init status --wait
test -f /var/db/freebsd-jail-node-ready
wg --version
sysrc jail_enable
```

The host bridge uses MTU 1496. Do not encode runtime tap numbers or bhyve process IDs into automation.

## Change an existing guest loader

```sh
sudo sh scripts/migrate_vm_to_bhyveload.sh db-node-03
```

The script restores the previous configuration and loader if the guarded restart fails.

## Deprovision

```sh
sudo make deprovision-vm VM_NAME=db-node-01
```

Equivalent direct command:

```sh
sudo PGDATABASE=inventory PGUSER=postgres \
  sh scripts/deprovision_vm.sh db-node-01
```

Deprovisioning removes the Kea reservation and active lease when present, destroys the guest, archives the inventory row by UUID, and releases the IP allocation. Missing guest or reservation state is tolerated to support stale-state cleanup.

## Inspect state

```sh
vm list
jls
container list 2>/dev/null || true
sudo -u postgres psql -d inventory -c 'TABLE vms;'
sudo -u postgres psql -d inventory -c 'TABLE ipam_leases;'
pfctl -sr
sockstat -4 -6 -l
service unbound status
drill @10.0.20.1 freebsd.org
```

Query database-backed Kea reservations for subnet `1`:

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

Use the subnet ID stored in `ipam_pools`. `curl --user` exposes the expanded credential to local process inspection, so run this only on the trusted host or use a protected curl configuration file.

## Service management

```sh
sh scripts/start_services.sh
container list
jls
service stork_server status
service stork_agent status
service unbound status
```

Validate service configuration inside jails when applicable:

```sh
jexec postgres psql -U postgres -d inventory
jexec kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
```

Stork uses separate `stork` and `kea_hosts` databases. Back them up independently from `inventory`.

## Recover interrupted provisioning

Set the affected name and inspect each state domain:

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
     JOIN vms v ON v.pool_id = l.pool_id
              AND v.ip_address = l.ip_address
    WHERE v.name = '${VM_NAME}'
    ORDER BY l.allocated_at DESC;"

zfs list -r zroot/vm | grep "$VM_NAME" || true
```

Then compare inventory with:

- the vm-bhyve guest and MAC configuration;
- the IPAM lease;
- the PostgreSQL-backed Kea reservation;
- any active DHCP lease;
- the guest zvol and seed image.

Do not reuse an address until all state agrees. For ordinary stale-state cleanup, run deprovisioning instead of editing databases manually.

A reconciliation job should report at least:

- inventory without a guest;
- guest without inventory;
- inventory without a Kea reservation;
- Kea reservation without inventory;
- released IPAM address with an active reservation or lease;
- independent inventories using the same `CONTROL_PLANE_ID`.

## Cloud-image cache

Validate or repair the cache by rerunning:

```sh
sudo make fetch-cloud-image
```

Default files:

```text
/var/cache/control-plane/freebsd-cloud.raw
/var/cache/control-plane/freebsd-cloud.raw.verified
```

The fetcher reuses the raw image only when its source and digest match the marker. To rotate images, update the URL and optional pinned digest together, refresh the cache, and test a disposable guest.

Do not edit the marker manually. Both cache files may be removed when no provisioning process is using them; the next fetch recreates them atomically.

## Backups

Back up:

- `/etc/rc.conf`, `/etc/pf.conf`, `/etc/jail.conf`, `/etc/ssh`, and `/etc/blacklistd.conf`;
- `/usr/local/etc/kea`, `/usr/local/etc/unbound`, and `/usr/local/etc/stork`;
- PostgreSQL databases `inventory`, `kea_hosts`, and `stork`;
- `/var/lib/stork-agent`;
- vm-bhyve templates and guest definitions;
- ZFS snapshots and replication targets;
- SSH host keys and future CA trust anchors;
- site-controlled image URLs, pinned digests, and `CONTROL_PLANE_ID`.

The verified cloud-image cache is reproducible and does not need backup when its source and digest policy are recorded.

## Change control

Before applying changes:

```sh
make lint
make test
make validate-freebsd
pfctl -nf /etc/pf.conf
```

After schema or service changes, verify the authenticated Kea API and complete one disposable provision/deprovision cycle before production use.
