# Security model

## Assets

- Administrative SSH access
- SSH host keys and future SSH CA trust anchor
- VM inventory and ownership metadata
- IP allocation state
- Kea reservation state
- VM disks and snapshots
- Management, VM, and external network boundaries

## Controls

### Administrative access

OpenSSH denies root login and password-based authentication. Access is limited to a management group and management network. `blacklistd` suppresses repeated abusive connection attempts; it does not replace key-only authentication.

A future `TrustedUserCAKeys` deployment should issue short-lived SSH user certificates through an approved CA workflow rather than copying permanent keys between hosts.

### Network exposure & Jail Isolation

PF uses default deny. Control plane services (PostgreSQL, Kea DHCP4, Prometheus, Grafana, Node Exporter, Postgres Exporter) are containerized and isolated inside FreeBSD Jails (`jail.conf`). SSH and Grafana are management-only. DHCP and DNS are bridge-only. Kea Control Agent and PostgreSQL remain loopback-bound within their service jail boundaries.

### Inventory and IPAM

PostgreSQL is authoritative for intended allocation state. The allocation function locks the selected pool before choosing an address, preventing two concurrent transactions from selecting the same free address in that pool.

Database uniqueness constraints provide secondary enforcement for VM names, MAC addresses, datasets, and IP addresses.

### Kea API

The Control Agent listens on loopback and is not authenticated by default. Remote access should use a separately authenticated TLS reverse proxy on the management network; direct exposure is prohibited.

JSON payloads are generated with `jq`, and the provisioner checks Kea result codes before continuing.

### Provisioning

VM names and template identifiers are restricted before use. Database literals are escaped. Provisioning records `running` only after `vm start` succeeds. Failure paths attempt compensating rollback.

Compensation is best effort. A host crash can leave partial state, requiring reconciliation across vm-bhyve, PostgreSQL, and Kea.

## Residual risks

- Shell orchestration is not a durable transaction coordinator.
- Local PostgreSQL authentication must be configured correctly.
- Kea hook-library locations vary by package build.
- Human-readable `vm info` parsing may change between vm-bhyve versions.
- ZFS workload tuning requires measurement; `primarycache=metadata` is not universally optimal.
