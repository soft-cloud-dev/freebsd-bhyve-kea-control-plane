# Security model

## Assets

- Administrative SSH access
- SSH host keys and future SSH CA trust anchor
- VM inventory and ownership metadata
- IP allocation state
- Kea reservation state
- Stork users, sessions, agent certificates, and tokens
- VM disks and snapshots
- Management, VM, and external network boundaries

## Controls

### Administrative access

OpenSSH denies root login and password-based authentication. Access is limited to a management group and management network. `blacklistd` suppresses repeated abusive connection attempts; it does not replace key-only authentication.

A future `TrustedUserCAKeys` deployment should issue short-lived SSH user certificates through an approved CA workflow rather than copying permanent keys between hosts.

### Network exposure & Jail Isolation

PF uses default deny. Control plane services are isolated with FreeBSD Jails where service discovery allows it. SSH, Grafana, and the Stork UI are management-only. DHCP and DNS are bridge-only. Unbound listens only on `10.0.20.1` and accepts queries only from `10.0.20.0/24`. VM traffic is forwarded and NATed through the external interface, while PF blocks VM-initiated access to the management network and host services other than DHCP, DNS, and ICMP. Kea Control Agent, the Stork agent, Stork’s Kea exporter, and PostgreSQL remain loopback-bound.

The Stork agent intentionally runs on the Kea host rather than in an isolated jail because it must inspect the Kea process and configuration. It runs as a dedicated unprivileged user with group-only read access to the Kea API credentials. Agent/server traffic is upgraded to mutual TLS during registration. Verify the pending agent token before authorization.

### Inventory and IPAM

PostgreSQL is authoritative for intended allocation state. The allocation function locks the selected pool before choosing an address, preventing two concurrent transactions from selecting the same free address in that pool.

Database uniqueness constraints provide secondary enforcement for VM names, MAC addresses, datasets, and IP addresses.

### Kea API

The Control Agent listens on loopback and is not authenticated by default. Remote access should use a separately authenticated TLS reverse proxy on the management network; direct exposure is prohibited.

JSON payloads are generated with `jq`, and the provisioner checks Kea result codes before continuing.

### Stork

The UI is restricted to the management network by its bind address and PF. Both service users share traversal-only access to `/usr/local/etc/stork`; the environment files remain group-readable only by their respective service accounts. The generated database password is readable only by the `stork-server` service group. Change the initial `admin` password at first login. Production deployments should enable TLS directly or use an authenticated TLS reverse proxy; the repository’s initial HTTP setup is suitable only for a trusted management segment.

### Provisioning

VM names and template identifiers are restricted before use. Database literals are escaped. Provisioning records `running` only after `vm start` succeeds. Failure paths attempt compensating rollback.

Compensation is best effort. A host crash can leave partial state, requiring reconciliation across vm-bhyve, PostgreSQL, and Kea.

## Residual risks

- Shell orchestration is not a durable transaction coordinator.
- Local PostgreSQL authentication must be configured correctly.
- Kea hook-library locations vary by package build.
- Human-readable `vm info` parsing may change between vm-bhyve versions.
- ZFS workload tuning requires measurement; `primarycache=metadata` is not universally optimal.
- ISC does not regularly test Stork on FreeBSD, so source builds and upgrades require target-host validation.
