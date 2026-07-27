# Operations

## Provision a VM

```sh
PGDATABASE=inventory \
PGUSER=postgres \
IPAM_POOL=vm-lan \
VM_OWNER=admin \
sh scripts/provision_vm.sh db-node-01 freebsd
```

The operation succeeds only after the VM starts and the inventory row is marked `running`. Earlier failures trigger compensating cleanup of Kea, PostgreSQL, IPAM, and vm-bhyve state.

## Remove a VM

```sh
PGDATABASE=inventory \
PGUSER=postgres \
sh scripts/rollback_vm.sh db-node-01
```

The command removes the Kea reservation first, destroys the guest, archives the inventory row, and releases the address.

## Inspect state

```sh
vm list
sudo -u postgres psql -d inventory -c 'TABLE vms;'
sudo -u postgres psql -d inventory -c 'TABLE ipam_leases;'
pfctl -sr
pfctl -a 'blacklistd/*' -sr
sockstat -4 -6 -l
```

## Failure handling

If provisioning is interrupted after an external side effect, inspect all three state domains:

```sh
vm info VM_NAME
sudo -u postgres psql -d inventory -c "SELECT * FROM vms WHERE name = 'VM_NAME';"
curl -fsS -H 'Content-Type: application/json' \
  -d '{"command":"reservation-get-all","service":["dhcp4"]}' \
  http://127.0.0.1:8000/ | jq .
```

Do not reuse an IP address until both the active inventory row and Kea reservation are resolved.

## Backups

Back up:

- `/etc/rc.conf`, `/etc/pf.conf`, `/etc/ssh`, and `/etc/blacklistd.conf`
- `/usr/local/etc/kea`
- PostgreSQL inventory using `pg_dump`
- vm-bhyve templates and guest definitions
- ZFS snapshots and replication targets
- SSH host keys and the future SSH CA trust anchor

## Change control

Before applying changes:

```sh
make lint
make validate-freebsd
pfctl -nf /etc/pf.conf
kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
kea-ctrl-agent -t /usr/local/etc/kea/kea-ctrl-agent.conf
```
