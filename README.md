# FreeBSD bhyve + Kea Control Plane

A minimal FreeBSD-native control plane for trusted SSH access, ZFS-backed `vm-bhyve` guests, transactional PostgreSQL inventory/IPAM, Kea DHCP reservations, PF trust boundaries, and Stork-compatible observability.

## Architecture

```text
SSH trust / FreeIPA CA
          |
      FreeBSD host
          |
  +-------+--------+----------------+
  |                |                |
ZFS + vm-bhyve  PostgreSQL       Kea DHCP4
  |            inventory/IPAM       |
  +----------------+----------------+
                   |
                bridge0
                   |
                bhyve VMs
```

PostgreSQL is the authoritative inventory. Kea is the runtime DHCP service. The provisioner coordinates both and rolls back partial changes.

## Repository layout

```text
config/
  kea-ctrl-agent.conf
  kea-dhcp4.conf
  pf.conf
  rc.conf.example
db/
  001_inventory.sql
scripts/
  01_host_setup.sh
  02_install_dependencies.sh
  provision_vm.sh
  rollback_vm.sh
```

## Security model

- SSH accepts public keys only and denies root login.
- `blacklistd` complements key-only SSH by suppressing repeated connection abuse.
- PF defaults to deny and exposes SSH, DHCP, DNS, and observability only on their intended interfaces.
- Kea Control Agent listens on `127.0.0.1:8000` only.
- PostgreSQL should use a local Unix socket and a dedicated operating-system role.
- Provisioning inputs are syntactically restricted before reaching `vm-bhyve`, SQL, or JSON.
- Kea API responses are validated; failed operations trigger compensating rollback.

## Installation

Review all interface names, networks, package versions, and service paths before execution.

```sh
su -
sh scripts/02_install_dependencies.sh
sh scripts/01_host_setup.sh
install -m 0600 config/pf.conf /etc/pf.conf
install -m 0644 config/kea-dhcp4.conf /usr/local/etc/kea/kea-dhcp4.conf
install -m 0644 config/kea-ctrl-agent.conf /usr/local/etc/kea/kea-ctrl-agent.conf
pfctl -nf /etc/pf.conf
kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
kea-ctrl-agent -t /usr/local/etc/kea/kea-ctrl-agent.conf
```

Initialize PostgreSQL and inventory:

```sh
service postgresql initdb
service postgresql start
sudo -u postgres createdb inventory
sudo -u postgres psql -d inventory -f db/001_inventory.sql
sudo -u postgres psql -d inventory <<'SQL'
INSERT INTO ipam_pools(name, subnet, first_host, last_host, vlan, kea_subnet_id)
VALUES ('vm-lan', '10.0.20.0/24', '10.0.20.10', '10.0.20.99', 20, 1)
ON CONFLICT (name) DO NOTHING;
SQL
```

Initialize `vm-bhyve` after reviewing its datastore and bridge configuration:

```sh
vm init
service pf start
service kea_dhcp4 start
service kea_ctrl_agent start
```

## Provisioning

The scripts expect local PostgreSQL authentication to permit the invoking administrative role. Prefer a dedicated database role over long-term use of `postgres`.

```sh
chmod 0750 scripts/*.sh
PGDATABASE=inventory \
PGUSER=postgres \
IPAM_POOL=vm-lan \
VM_OWNER=admin \
sh scripts/provision_vm.sh db-node-01 freebsd
```

Deprovision:

```sh
PGDATABASE=inventory PGUSER=postgres sh scripts/rollback_vm.sh db-node-01
```

## Operational checks

```sh
sshd -t
pfctl -nf /etc/pf.conf
pfctl -sr
sockstat -4 -6 -l
service blacklistd status
service postgresql status
service kea_dhcp4 status
service kea_ctrl_agent status
vm list
sudo -u postgres psql -d inventory -c 'TABLE vms;'
```

## Known boundaries

- The `vm info` parser is isolated but still depends on human-readable `vm-bhyve` output. Replace it when a stable machine-readable interface is available.
- `xattr=sa` is attempted and automatically falls back to `xattr=on` when unsupported.
- `volblocksize` is a zvol creation-time property and must be selected in each VM/template path.
- Stork is not installed automatically because FreeBSD package availability and deployment topology vary. It may run on a management VM or another supported host while its agent observes Kea.
- The provided Kea and PF configurations are examples. Interface names, paths, and hook-library packaging must be verified on the target FreeBSD release.

## License

BSD-2-Clause is recommended for this repository. Add the copyright holder and year before distribution.
