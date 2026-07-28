# Operations

## Provision a VM

The provisioner creates a NoCloud seed ISO containing the VM identity, local hostname, management user, and trusted Ed25519 SSH public key. Supply the key through a file where possible so it does not enter shell history.

```sh
PGDATABASE=inventory \
PGUSER=postgres \
IPAM_POOL=vm-lan \
VM_OWNER=admin \
CLOUD_INIT_USER=admin \
SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
sh scripts/provision_vm.sh db-node-01 freebsd
```

For automation, `SSH_AUTHORIZED_KEY` may contain the complete public-key line directly.

The operation succeeds only after:

1. vm-bhyve creates the guest;
2. a `cidata` NoCloud seed ISO is created as `seed.iso` in the guest directory;
3. PostgreSQL allocates and records the address;
4. Kea accepts the reservation;
5. the VM starts; and
6. the inventory row is marked `running`.

Earlier failures trigger compensating cleanup of temporary seed inputs, Kea, PostgreSQL, IPAM, and vm-bhyve state.

The guest image must include cloud-init with the NoCloud datasource enabled. The selected vm-bhyve template must attach `seed.iso` as a CD-ROM.

## Remove a VM

```sh
PGDATABASE=inventory \
PGUSER=postgres \
sh scripts/rollback_vm.sh db-node-01
```

The command removes the Kea reservation first, destroys the guest and its seed ISO, archives the inventory row, and releases the address.

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

## Service management

Manage control plane service containers (FreeBSD Jails):

```sh
# Start all control plane service containers/jails:
sh scripts/start_services.sh

# Manage individual FreeBSD jails:
jls
jexec postgres psql -U postgres -d inventory
jexec kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
service stork_server status
service stork_agent status
service unbound status
```

The Stork dashboard is at `http://MGMT_ADDR:8080`. Its database and the Kea hosts database are separate from `inventory`. Back them up with:

```sh
sudo -u postgres pg_dump -Fc stork > stork.dump
sudo -u postgres pg_dump -Fc kea_hosts > kea-hosts.dump
```

## Failure handling

If provisioning is interrupted after an external side effect, inspect all state domains:

```sh
vm info VM_NAME
sudo -u postgres psql -d inventory -c "SELECT * FROM vms WHERE name = 'VM_NAME';"
curl -fsS -H 'Content-Type: application/json' \
  -d '{"command":"reservation-get-all","service":["dhcp4"]}' \
  http://127.0.0.1:8000/ | jq .
jls
```

Do not reuse an IP address until both the active inventory row and Kea reservation are resolved.

## Backups

Back up:

- `/etc/rc.conf`, `/etc/pf.conf`, `/etc/jail.conf`, `/etc/ssh`, and `/etc/blacklistd.conf`
- `/usr/local/etc/kea`
- `/usr/local/etc/unbound`
- `/usr/local/etc/stork`, `/var/lib/stork-agent`, and the Stork PostgreSQL database
- the Kea PostgreSQL hosts database and `/usr/local/etc/kea/kea-host-db-password`
- PostgreSQL inventory using `pg_dump`
- vm-bhyve templates and guest definitions
- ZFS snapshots and replication targets
- SSH host keys and future SSH CA trust anchors

## Change control

Before applying changes:

```sh
make lint
make validate-freebsd
pfctl -nf /etc/pf.conf
```
