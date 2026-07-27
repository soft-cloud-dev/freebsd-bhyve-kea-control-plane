# FreeBSD bhyve + Kea Control Plane

A minimal FreeBSD-native control plane for trusted SSH access, ZFS-backed `vm-bhyve` guests, transactional PostgreSQL inventory/IPAM, Kea DHCP reservations, PF trust boundaries, Prometheus metrics, and Grafana dashboards.

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

node_exporter + postgres_exporter
              |
         Prometheus
              |
           Grafana
```

PostgreSQL is the authoritative inventory. Kea is the runtime DHCP service. The provisioner coordinates both and rolls back partial changes. Prometheus and exporters remain loopback-only; Grafana is exposed only on the management VLAN.

## Repository layout

```text
config/
  grafana.ini
  grafana/provisioning/
  kea-ctrl-agent.conf
  kea-dhcp4.conf
  pf.conf
  prometheus.yml
  rc.conf.example
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
- PF defaults to deny and exposes SSH, DHCP, DNS, Grafana, and optional Stork only on their intended interfaces.
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
install -m 0600 config/pf.conf /etc/pf.conf
install -m 0644 config/kea-dhcp4.conf /usr/local/etc/kea/kea-dhcp4.conf
install -m 0644 config/kea-ctrl-agent.conf /usr/local/etc/kea/kea-ctrl-agent.conf
install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml
install -m 0644 config/grafana.ini /usr/local/etc/grafana/grafana.ini
pfctl -nf /etc/pf.conf
kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
kea-ctrl-agent -t /usr/local/etc/kea/kea-ctrl-agent.conf
promtool check config /usr/local/etc/prometheus.yml
```

Initialize PostgreSQL and inventory:

```sh
service postgresql initdb
service postgresql start
sudo -u postgres createdb inventory
sudo -u postgres psql -d inventory -f db/001_inventory.sql
sudo -u postgres psql -d inventory -f db/002_monitoring.sql
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
service kea_dhcp4 start
service kea_ctrl_agent start
service node_exporter start
service postgres_exporter start
service prometheus start
service grafana start
```

The complete sequence is documented in `docs/installation.md` and `docs/observability.md`.

## Provisioning

```sh
chmod 0750 scripts/*.sh tests/*.sh
PGDATABASE=inventory \
PGUSER=postgres \
IPAM_POOL=vm-lan \
VM_OWNER=admin \
CLOUD_INIT_USER=admin \
SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" \
sh scripts/provision_vm.sh db-node-01 freebsd
```

Deprovision:

```sh
PGDATABASE=inventory PGUSER=postgres sh scripts/rollback_vm.sh db-node-01
```

## Validation

```sh
make lint
make test
make validate-freebsd
promtool check config /usr/local/etc/prometheus.yml
sockstat -4 -6 -l
service prometheus status
service grafana status
```

## Known boundaries

- The `vm info` parser is isolated but still depends on human-readable `vm-bhyve` output.
- `xattr=sa` is attempted and falls back to `xattr=on` when unsupported.
- `volblocksize` is a zvol creation-time property and must be selected in each VM/template provisioning path.
- Grafana is configured for management-network HTTP initially; production TLS and secure cookies require site-specific hostname and certificate decisions.
- Stork remains optional because server and agent packaging may vary across supported environments.
- Interface names, package names, rc.d variables, and hook-library paths must be verified on the target FreeBSD release and package repository branch.

## License

BSD-3-Clause. See `LICENSE`.
