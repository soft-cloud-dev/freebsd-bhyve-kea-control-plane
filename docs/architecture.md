# Architecture

## Responsibilities

| Component | Authority |
|---|---|
| OpenSSH / future FreeIPA SSH CA | Administrative identity and host trust |
| PostgreSQL inventory database | VM inventory and IP allocation state |
| PostgreSQL Kea hosts database | DHCP reservation state used by the provisioner and Stork |
| PostgreSQL Stork database | Stork application state |
| Kea DHCP4 | Runtime delivery of network configuration and leases |
| Unbound | Restricted validating, recursive DNS for the VM LAN |
| vm-bhyve | Guest lifecycle |
| ZFS | Guest storage |
| PF and blacklistd | Network boundary enforcement and abuse suppression |
| Container CLI (`container`) | Lifecycle engine for control-plane service containers |
| Stork server + host agent | Kea operations, dashboard, and metrics plane |

PostgreSQL inventory is authoritative for intended VM and IPAM state. Kea reservations have exactly one writable authority: the dedicated PostgreSQL hosts database. Runtime provisioning does not copy reservations into `kea-dhcp4.conf`; static configuration rendering clears per-subnet reservation arrays whenever the PostgreSQL hosts backend is enabled.

## Provisioning sequence

```text
validate request and reject stale/duplicate state
      |
create vm-bhyve definition
      |
verify the FreeBSD image checksum and cache marker
      |
write verified image to the guest zvol
      |
transactionally allocate IP and collision-checked MAC
      |
insert provisioning inventory record
      |
write allocated MAC into the vm-bhyve configuration
      |
create cloud-init seed
      |
add reservation to the PostgreSQL Kea hosts backend
      |
start VM
      |
mark inventory running
```

MAC allocation is serialized with a PostgreSQL transaction-level advisory lock. The allocator derives a locally administered unicast address from a stable control-plane namespace, VM name, and collision-attempt counter. Active inventory uniqueness remains the final database constraint.

Each completed external action has a compensating rollback action. The shell script coordinates the sequence but is not itself a durable workflow engine.

## Image trust

The cloud-image fetcher obtains the release `CHECKSUM.SHA256` file unless an explicit digest is supplied. It verifies the compressed image before decompression, computes a digest for the raw cache, and writes a sidecar marker containing the source URL, compressed digest, and raw digest. A cached image is reused only when the marker matches and the raw digest verifies. Downloads and marker creation occur in a temporary directory on the cache filesystem before atomic renames.

## Trust boundaries

- The Kea Control Agent binds only to loopback and requires HTTP Basic authentication.
- PostgreSQL is expected to use a local Unix socket for the provisioner.
- SSH is accepted only on the management interface and from the management subnet.
- DHCP and internal DNS are accepted only on the VM bridge.
- Unbound listens only on `10.0.20.1` and accepts queries only from `10.0.20.0/24`.
- Observability endpoints are exposed only on the management interface.
- The Stork server UI binds to the management address. The local Stork agent and its Kea exporter bind only to loopback.
- PF starts from a default-deny policy.

## Storage

The parent VM dataset uses compression, disabled access-time updates, metadata-only ARC caching, and standard synchronous-write semantics. `volblocksize` is selected when each zvol is created; it is not a normal inheritable dataset default.

The example vm-bhyve template uses a sparse zvol. `disk0_opts` contains only options accepted by bhyve. ZFS creation properties must be applied separately.

## Known limits

- Shell traps provide best-effort compensation, not crash-safe distributed transactions.
- A host crash can leave external state requiring reconciliation even though normal failure paths compensate completed actions.
- `CONTROL_PLANE_ID` should be explicitly set to a stable cluster identifier when hostnames or `/etc/hostid` values are not durable.
- Interface names, Kea hook paths, and package versions vary by FreeBSD release and repository branch.
- ISC does not publish native FreeBSD packages for Stork. The installer therefore builds a pinned ISC source release and installs FreeBSD rc.d services.
