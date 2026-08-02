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
  |       Kea hosts + Stork DB      +-- Stork agent
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

Stork server (management + VM-LAN TCP/8080) <---- Stork agent (loopback TCP/8081)
```

PostgreSQL is authoritative for inventory and IPAM. A separate PostgreSQL hosts database is the sole writable authority for Kea reservations, allowing Stork and the provisioner to share the Host Commands API without copying runtime reservations into `kea-dhcp4.conf`.

VM MAC addresses are allocated transactionally by PostgreSQL from a stable control-plane namespace and checked against active inventory. FreeBSD cloud images are accepted only after SHA-256 verification and are reused only when their verification marker and raw-cache digest remain valid.

Unbound provides validating recursive DNS to the VM LAN on `10.0.20.1` only. PF blocks VM access to the management network and host services other than DHCP, DNS, ICMP, and the Stork UI. The Kea Control Agent, Prometheus, Loki, and exporters remain loopback-only. Grafana is management-only; Stork is reachable from the trusted management and VM subnets.

## Repository layout

```text
config/                         service and policy configuration
db/                             inventory, monitoring, and MAC allocator SQL
docs/                           architecture, installation, operations, security, testing
scripts/                        host setup, service setup, provisioning, rollback
config/cloud-init/              FreeBSD guest profiles
templates/                      vm-bhyve templates
tests/                          portable and service configuration tests
.github/workflows/              portable, FreeBSD VM, and bare-metal E2E workflows
Makefile
LICENSE
```

## Security model

- SSH accepts public keys only and denies root login.
- `blacklistd` complements key-only SSH by suppressing repeated connection abuse.
- PF defaults to deny and exposes services only on their intended interfaces.
- Kea Control Agent binds to loopback and requires HTTP Basic authentication.
- Runtime Kea reservation mutations explicitly target the PostgreSQL hosts database.
- Provisioning inputs are restricted before reaching `vm-bhyve`, SQL, JSON, or cloud-init YAML.
- Cloud images are checksum-verified before they are written to guest storage.
- Failed provisioning operations trigger best-effort compensating rollback.

See `docs/security-model.md`, `docs/architecture.md`, and `docs/operations.md`.

## Installation

Review interface names, networks, package versions, service paths, database authentication, Grafana bindings, `CONTROL_PLANE_ID`, and cloud-image checksum policy before execution.

```sh
su -
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

The installation initializes PostgreSQL inventory, the Kea hosts backend, Stork, service configuration, IPAM, vm-bhyve, PF, DNS, and observability services. The standard FreeBSD Kea package omits PostgreSQL support; when required, the dependency stage rebuilds `net/kea` from ports with `PGSQL` enabled.

Initialize the vm-bhyve datastore and install the template after reviewing its storage and network settings:

```sh
vm init
install -m 0644 templates/vm-bhyve.conf /zroot/vm/.templates/freebsd.conf
```

Pre-fetch and verify the FreeBSD cloud image:

```sh
make fetch-cloud-image
```

The fetcher derives `CHECKSUM.SHA256` from the image directory. A site may instead pin the compressed digest with `FREEBSD_CLOUD_IMAGE_SHA256` or override `FREEBSD_CLOUD_IMAGE_CHECKSUM_URL`.

The complete procedure is in `docs/installation.md`.

## Upgrade from the earlier reservation model

Existing installations must apply the MAC allocator schema and remove static runtime reservations from the rendered Kea configuration.

1. Back up `inventory`, `kea_hosts`, and `/usr/local/etc/kea/kea-dhcp4.conf`.
2. Run `sh scripts/init_postgresql.sh` to apply `db/003_mac_allocator.sql`.
3. Re-run `make configure-services` with the site's existing interface, address, and database values.
4. Confirm `hosts-databases` contains PostgreSQL and every subnet reservation array is empty.
5. Validate with `kea-dhcp4 -t`, restart through `scripts/start_services.sh`, and run `make validate-freebsd`.
6. Verify an existing reservation through the authenticated loopback API and complete one disposable provision/deprovision cycle.

Detailed commands and rollback precautions are in `docs/installation.md#upgrade-an-existing-installation`.

## Provisioning

`vm-bhyve` and ZFS administration require root privileges. Set `CONTROL_PLANE_ID` to a stable cluster identifier. When omitted, the provisioner uses `/etc/hostid` and then the hostname as fallbacks.

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

The provisioning path performs:

```text
preflight
  -> verify/cache image
  -> create guest and write verified image
  -> transactionally allocate IP/MAC and insert inventory
  -> persist MAC and create cloud-init seed
  -> add authenticated PostgreSQL-backed Kea reservation
  -> boot
  -> finalize inventory by UUID
```

Deprovision:

```sh
sudo make deprovision-vm VM_NAME=db-node-01
```

Operational diagnostics, authenticated Kea queries, reconciliation, backups, and image-cache maintenance are in `docs/operations.md`.

## Stork

Stork is enabled by default. Its server and agent are built from pinned ISC `v2.5.0` source because ISC does not publish native FreeBSD packages. Set `STORK_ENABLE=no` to omit it.

After startup, open `http://10.0.10.2:8080` from a trusted subnet, sign in with the initial `admin` / `admin` credentials, change the password immediately, and authorize the pending local agent under **Services -> Machines -> Unauthorized**.

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

Testing is split into:

- portable CI on Ubuntu for syntax, error-level ShellCheck, repository tests, JSON/YAML validation, secret scanning, authority invariants, and image-cache integrity;
- FreeBSD VM integration for a real authenticated Kea reservation lifecycle;
- manually triggered bare-metal bhyve E2E for VM boot, cloud-init SSH, PostgreSQL-backed reservation verification, and cleanup.

See `docs/testing.md`.

## Known boundaries

- `vm-bhyve` and ZFS administration require root privileges.
- Shell traps provide best-effort compensation, not crash-safe distributed transactions.
- A host crash can require reconciliation across vm-bhyve, ZFS, PostgreSQL, IPAM, Kea reservations, and DHCP leases.
- The default image path trusts the checksum obtained from the same HTTPS release origin unless a digest is independently pinned.
- The standard FreeBSD Kea package does not enable PostgreSQL support; the dependency stage rebuilds it from ports when necessary.
- Production requires a FreeBSD release supported by the FreeBSD Security Team.
- Stork subnet editing requires `libdhcp_subnet_cmds.so` and the expected Kea package generation.
- Grafana and Stork use HTTP initially; production TLS requires site-specific hostname and certificate decisions.
- ISC does not regularly test Stork on FreeBSD; validate the pinned release on the target host.
- Interface names, package names, rc.d variables, and hook-library paths vary by FreeBSD release and repository branch.

## License

BSD-3-Clause. See `LICENSE`.
