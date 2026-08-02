# Security model

## Assets

- Administrative SSH access
- SSH host keys and future SSH CA trust anchor
- VM inventory and ownership metadata
- IP allocation and MAC allocation state
- Kea reservation state
- Kea API and PostgreSQL hosts-database credentials
- Stork users, sessions, agent certificates, and tokens
- Verified FreeBSD cloud-image cache and verification metadata
- VM disks and snapshots
- Management, VM, and external network boundaries

## Controls

### Administrative access

OpenSSH denies root login and password-based authentication. Access is limited to a management group and management network. `blacklistd` suppresses repeated abusive connection attempts; it does not replace key-only authentication.

A future `TrustedUserCAKeys` deployment should issue short-lived SSH user certificates through an approved CA workflow rather than copying permanent keys between hosts.

### Network exposure and jail isolation

PF uses default deny. Control-plane services are isolated with FreeBSD jails where service discovery allows it. SSH and Grafana are management-only. The Stork UI is available from management and the VM LAN on TCP/8080, but remains blocked on the external interface. DHCP and DNS are bridge-only. Unbound listens only on `10.0.20.1` and accepts queries only from `10.0.20.0/24`. VM traffic is forwarded and NATed through the external interface, while PF blocks VM-initiated access to the management network and host services other than DHCP, DNS, ICMP, and Stork. Kea Control Agent, the Stork agent, Stork's Kea exporter, and PostgreSQL remain loopback-bound.

The Stork agent intentionally runs on the Kea host rather than in an isolated jail because it must inspect the Kea process and configuration. It runs as a dedicated unprivileged user with group-only read access to the Kea API credentials. Agent/server traffic is upgraded to mutual TLS during registration. Verify the pending agent token before authorization.

### Inventory, IPAM, and MAC allocation

PostgreSQL is authoritative for intended VM and allocation state. The IP allocation function locks the selected pool before choosing an address, preventing concurrent transactions from selecting the same free address in that pool.

MAC allocation runs inside the same provisioning transaction and is serialized with a PostgreSQL transaction-level advisory lock. Candidates are derived from a stable `CONTROL_PLANE_ID`, VM name, and collision-attempt counter. The generated address is locally administered and unicast. Active database uniqueness constraints provide final enforcement for VM names, MAC addresses, datasets, and IP addresses.

Set `CONTROL_PLANE_ID` explicitly when `/etc/hostid` or the hostname is not a durable cluster identity. Reusing the same namespace across independent control planes is safe only when their active inventory is shared.

### Kea API and reservation authority

The Kea Control Agent listens on loopback and requires HTTP Basic authentication. The provisioner and rollback scripts read the username and password from `/usr/local/etc/kea/kea-api-user` and `/usr/local/etc/kea/kea-api-password` unless alternate paths are supplied. Direct network exposure is prohibited; remote administration should use an authenticated TLS management proxy or an SSH tunnel.

JSON payloads are generated with `jq`, and callers validate Kea result codes. Runtime reservation mutations explicitly use `operation-target: database`. The dedicated PostgreSQL Kea hosts database is the sole writable reservation authority; runtime provisioning does not append reservations to `kea-dhcp4.conf`. Static per-subnet reservation arrays are cleared when configuration is rendered with the PostgreSQL hosts backend enabled.

The Kea hosts database uses a dedicated account and a generated password stored with restrictive permissions. Protect the rendered Kea configuration because it contains the database credential. Back up the hosts database and credential file together.

### Cloud-image trust

The image fetcher verifies the compressed FreeBSD image against either `FREEBSD_CLOUD_IMAGE_SHA256` or the release `CHECKSUM.SHA256` file before decompression. It computes a digest for the raw cache and records the source URL, compressed digest, and raw digest in a sidecar verification marker.

A cached raw image is reused only when the marker matches the configured source and the raw digest verifies. Downloads, decompression, and marker generation occur in a temporary directory on the cache filesystem before atomic rename. Provisioning writes only the verified raw cache to a guest zvol.

Checksum verification protects integrity, not publisher identity beyond the HTTPS and repository trust path. High-assurance deployments should pin `FREEBSD_CLOUD_IMAGE_SHA256` through an independently reviewed release process.

### Stork

The UI is restricted to the management network by its bind address and PF. Both service users share traversal-only access to `/usr/local/etc/stork`; the environment files remain group-readable only by their respective service accounts. The generated database password is readable only by the `stork-server` service group. Change the initial `admin` password at first login. Production deployments should enable TLS directly or use an authenticated TLS reverse proxy; the repository's initial HTTP setup is suitable only for a trusted management segment.

### Provisioning and compensation

VM names, template identifiers, cloud-init usernames, and public-key inputs are restricted before use. Database literals are escaped. Provisioning records `running` only after `vm start` succeeds. Kea reservations are created only after the inventory transaction returns the VM UUID, address, subnet, and MAC.

Failure paths attempt compensating rollback across Kea reservations and leases, vm-bhyve state, inventory, and IPAM. Compensation is best effort. A host crash can leave partial state, requiring reconciliation across vm-bhyve, PostgreSQL, Kea, ZFS, and the cloud-image cache.

## Residual risks

- Shell orchestration is not a durable transaction coordinator.
- Local PostgreSQL authentication and filesystem permissions must be configured correctly.
- Kea hook-library locations and package features vary by FreeBSD release and repository branch.
- `vm info` exit status is used as an existence probe; verify behavior after vm-bhyve upgrades.
- The default image-verification path trusts the release checksum obtained from the same HTTPS origin unless a digest is pinned independently.
- ZFS workload tuning requires measurement; `primarycache=metadata` is not universally optimal.
- ISC does not regularly test Stork on FreeBSD, so source builds and upgrades require target-host validation.
