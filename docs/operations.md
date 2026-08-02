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

The provisioner rejects duplicate state, verifies the image, creates the guest, allocates IP/MAC/inventory state, adds the PostgreSQL-backed Kea reservation, starts the VM, and marks it `running`. Failures trigger best-effort cleanup; host crashes may still require reconciliation.

The guest must support cloud-init NoCloud. The provisioner enforces `bhyveload` before first boot. `SSH_AUTHORIZED_KEY` may replace `SSH_PUBLIC_KEY_FILE`.

## Provision a three-node FreeBSD cluster

The cluster lifecycle bootstraps local `kubectl` access, provisions three jail-ready FreeBSD guests, waits for cloud-init over SSH, and writes a protected inventory.

```sh
sudo make cluster-up \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE=/root/.ssh/id_ed25519.pub \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519
```

Defaults:

```text
nodes                  freebsd-node-01 .. freebsd-node-03
node count             3
cloud-init profile     config/cloud-init/freebsd-jail-node.yaml
boot timeout           600 seconds per node
inventory              /var/db/freebsd-bhyve-kea-control-plane/clusters/freebsd-node.tsv
kubeconfig source      root@ipa.softcloud.dev:/etc/kubernetes/admin.conf
kubeconfig destination /root/.kube/config
control-plane hosts    /var/db/freebsd-bhyve-kea-control-plane/clusters/kubernetes-control-plane.known_hosts
```

Before creating a VM, `cluster-up` runs `bootstrap-kubectl`. The bootstrap target:

1. installs the FreeBSD `kubectl` package when missing;
2. uses `KUBECONFIG_SOURCE` when a readable local file is supplied;
3. otherwise reuses an existing destination unless `KUBECONFIG_REFRESH=yes`;
4. otherwise fetches the remote kubeconfig over batch-mode SSH;
5. installs it atomically with mode `0600`;
6. verifies the context and API with `kubectl cluster-info`.

Bootstrap or refresh access without provisioning guests:

```sh
sudo make bootstrap-kubectl \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519

sudo make bootstrap-kubectl \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519 \
  KUBECONFIG_REFRESH=yes
```

Override the Kubernetes control plane when needed:

```sh
sudo make bootstrap-kubectl \
  KUBECONFIG_REMOTE_HOST=control-plane.example.net \
  KUBECONFIG_REMOTE_USER=root \
  KUBECONFIG_REMOTE_PATH=/etc/kubernetes/admin.conf \
  KUBECONFIG_REMOTE_SSH_KEY=/root/.ssh/control-plane_ed25519
```

For a non-root remote account that has passwordless sudo permission to read the file:

```sh
sudo make bootstrap-kubectl \
  KUBECONFIG_REMOTE_USER=admin \
  KUBECONFIG_REMOTE_SUDO=yes \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519
```

SSH uses `StrictHostKeyChecking=accept-new` with a dedicated known-hosts file. A changed control-plane host key is rejected; review and remove the stale entry deliberately rather than disabling host-key verification.

The cluster workflow performs all VM and inventory conflict checks before creating a guest. If a later node fails, it deprovisions only nodes created by that run. A readable private key enables SSH/cloud-init readiness checks; without one, provisioning succeeds but readiness checks are skipped with a warning.

The profile installs WireGuard tooling and enables native jails. It does not generate WireGuard keys, peers, routes, or jail definitions. The FreeBSD guests are not configured as Kubernetes kubelet nodes; `kubectl` administers the existing Kubernetes API.

Inspect or remove the topology:

```sh
sudo make cluster-status
sudo make cluster-down
```

Override the topology when needed:

```sh
sudo make cluster-up \
  CLUSTER_NODE_PREFIX=lab-node \
  CLUSTER_NODE_COUNT=3 \
  CLUSTER_BOOT_TIMEOUT=900 \
  KUBECTL_BOOTSTRAP=no \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE=/root/.ssh/id_ed25519.pub \
  SSH_PRIVATE_KEY_FILE=/root/.ssh/id_ed25519
```

The legacy `scripts/provision_freebsd_jail_cluster.sh` entry point remains available and routes through the same lifecycle with the historical `jail-node-01` naming.

Single jail-ready guest:

```sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  CONTROL_PLANE_ID=softcloud-lab-01 \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_freebsd_jail_node.sh jail-node-01
```

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

## Deprovision a VM

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
- `/root/.kube/config` and the dedicated control-plane known-hosts file;
- site-controlled image URLs, pinned digests, `CONTROL_PLANE_ID`, and kubeconfig source settings.

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
