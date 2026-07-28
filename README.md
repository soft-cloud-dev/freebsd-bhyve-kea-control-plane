# FreeBSD bhyve + Kea Control Plane

A FreeBSD-native control plane for trusted SSH access, ZFS-backed `vm-bhyve` guests, transactional PostgreSQL inventory/IPAM, Kea DHCP reservations, Unbound DNS, the Stork Kea dashboard, PF trust boundaries, Prometheus metrics, and Grafana dashboards.

## Architecture

```text
SSH trust / FreeIPA CA
          |
      FreeBSD host
          |
  +-------+--------+----------------+
  |                |                |
ZFS + vm-bhyve  PostgreSQL       Kea DHCP4
  |          inventory/IPAM +       |
  |            Stork DB             +-- Stork agent
  +----------------+----------------+
                   |
                bridge0
                   |
                bhyve VMs

node_exporter + postgres_exporter + Stork Kea exporter
              |
         Prometheus
              |
           Grafana

Stork server (management TCP/8080) <---- Stork agent (loopback TCP/8081)
```

PostgreSQL is the authoritative inventory. Kea is the runtime DHCP service. Unbound provides validating, recursive DNS to the VM LAN on `10.0.20.1` only. The FreeBSD host forwards and NATs VM traffic through the external interface while PF blocks the VM LAN from the management network and host services other than DHCP, DNS, and ICMP. The provisioner coordinates PostgreSQL and Kea and rolls back partial changes. Stork provides the Kea operations dashboard and uses a separate PostgreSQL database. Prometheus and exporters remain loopback-only; Grafana and Stork are exposed only on the management VLAN.

## Repository layout

```text
config/
  grafana.ini
  grafana/provisioning/
  kea-ctrl-agent.conf
  kea-dhcp4.conf
  unbound.conf.in
  pf.conf
  prometheus.yml
  rc.conf.example
  rc.d/stork_{server,agent}
  stork/{server,agent}.env.in
db/
  001_inventory.sql
  002_monitoring.sql
docs/
  architecture.md
  installation.md
  observability.md
  operations.md
  security-model.md
scripts/
  01_host_setup.sh
  02_install_dependencies.sh
  init_stork.sh
  install_stork.sh
  provision_vm.sh
  rollback_vm.sh
templates/
  vm-bhyve.conf
tests/
  test_kea.sh
  test_pf.sh
  test_provisioner.sh
Makefile
LICENSE
```

## Security model

- SSH accepts public keys only and denies root login.
- `blacklistd` complements key-only SSH by suppressing repeated connection abuse.
- PF defaults to deny and exposes SSH, DHCP, DNS, Grafana, and Stork only on their intended interfaces.
- Kea Control Agent, Prometheus, node_exporter, postgres_exporter, and PostgreSQL remain local to the host.
- Provisioning inputs are syntactically restricted before reaching `vm-bhyve`, SQL, JSON, or cloud-init YAML.
- Kea API responses are validated; failed operations trigger compensating rollback.

See `docs/security-model.md` and `docs/observability.md`.

## Installation

Review all interface names, networks, package versions, service paths, database authentication, and Grafana bindings before execution.

```sh
su -
sh scripts/02_install_dependencies.sh
sh scripts/01_host_setup.sh
sh scripts/configure_services.sh
pfctl -nf /etc/pf.conf
kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
kea-ctrl-agent -t /usr/local/etc/kea/kea-ctrl-agent.conf
unbound-checkconf /usr/local/etc/unbound/unbound.conf
promtool check config /usr/local/etc/prometheus.yml
```

Initialize PostgreSQL and inventory:

```sh
sh scripts/init_postgresql.sh
sh scripts/init_stork.sh
sudo -u postgres psql -d inventory <<'SQL'
INSERT INTO ipam_pools(name, subnet, first_host, last_host, vlan, kea_subnet_id)
VALUES ('vm-lan', '10.0.20.0/24', '10.0.20.10', '10.0.20.99', 20, 1)
ON CONFLICT (name) DO NOTHING;
SQL
```

Initialize `vm-bhyve` after reviewing its datastore, switch, template, and bridge configuration:

```sh
vm init
install -m 0644 templates/vm-bhyve.conf /zroot/vm/.templates/freebsd.conf
```

Start services:

```sh
service pf start
sh scripts/start_services.sh
# or manage containers:
container list
```

The complete sequence is documented in `docs/installation.md` and `docs/observability.md`.

Stork is enabled by default. Its server and agent are built from the pinned official ISC `v2.5.0` source because ISC does not publish native FreeBSD packages. Set `STORK_ENABLE=no` to omit it. After startup, open `http://10.0.10.2:8080`, sign in with the initial `admin` / `admin` credentials, change the password immediately, and authorize the pending local agent under **Services → Machines → Unauthorized**.

## Provisioning

`vm-bhyve` and ZFS dataset administration require root privileges (via `sudo` or `su -`):

```sh
chmod 0750 scripts/*.sh tests/*.sh
sudo PGDATABASE=inventory \
  PGUSER=postgres \
  IPAM_POOL=vm-lan \
  VM_OWNER=admin \
  CLOUD_INIT_USER=admin \
  SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
  sh scripts/provision_vm.sh db-node-01 freebsd
```

Deprovision:

```sh
sudo PGDATABASE=inventory PGUSER=postgres sh scripts/rollback_vm.sh db-node-01
```

## Validation

```sh
make lint
make test
make validate-freebsd
promtool check config /usr/local/etc/prometheus.yml
sockstat -4 -6 -l
service unbound status
service prometheus status
service grafana status
```

## Known boundaries

- `vm-bhyve` and ZFS administration operations require `root` privileges.
- The `vm info` parser is isolated but still depends on human-readable `vm-bhyve` output.
- Kea DHCP reservations are updated dynamically in active server memory and written to disk via Control Agent API (`config-get`/`config-set`/`config-write`), avoiding dependency on external SQL host database hook plugins.
- Stork subnet editing uses Kea's open-source `libdhcp_subnet_cmds.so` hook and therefore requires the FreeBSD Kea 3.0+ package.
- `xattr=sa` is attempted and falls back to `xattr=on` when unsupported.
- `volblocksize` is a zvol creation-time property and must be selected in each VM/template provisioning path.
- Grafana is configured for management-network HTTP initially; production TLS and secure cookies require site-specific hostname and certificate decisions.
- Stork is source-built on FreeBSD and is not regularly tested there by ISC; validate the pinned release on the target FreeBSD version before production use.
- Interface names, package names, rc.d variables, and hook-library paths must be verified on the target FreeBSD release and package repository branch.

## License

BSD-3-Clause. See `LICENSE`.
