# Architecture

## Responsibilities

| Component | Authority |
|---|---|
| OpenSSH / future FreeIPA SSH CA | Administrative identity and host trust |
| PostgreSQL (Container) | VM inventory/IP allocation state and the separate Stork application database |
| Kea DHCP4 (Container) | Runtime delivery of network configuration |
| BIND 9 | Restricted recursive DNS for the VM LAN |
| vm-bhyve | Guest lifecycle |
| ZFS | Guest storage |
| PF and blacklistd | Network boundary enforcement and abuse suppression |
| Container CLI (`container`) | Lifecycle engine for control plane service containers |
| Stork server + host agent | Kea operations, dashboard, and metrics plane |

PostgreSQL is authoritative for intended VM and IPAM state. Kea reservations are derived runtime state. A reservation must therefore be removed or repaired when provisioning does not complete.

## Provisioning sequence

```text
validate request
      |
vm create from template
      |
read generated MAC
      |
lock IPAM pool and allocate address
      |
insert VM inventory record
      |
add Kea host reservation
      |
start VM
      |
mark inventory running
```

Each completed external action has a compensating rollback action. The shell script coordinates the sequence but is not itself a durable workflow engine.

## Trust boundaries

- The Kea Control Agent binds only to loopback.
- PostgreSQL is expected to use a local Unix socket for the provisioner.
- SSH is accepted only on the management interface and from the management subnet.
- DHCP and internal DNS are accepted only on the VM bridge.
- BIND listens only on `10.0.20.1` and permits queries and recursion only from `10.0.20.0/24`.
- Observability endpoints are exposed only on the management interface.
- The Stork server UI binds to the management address. The local Stork agent and its Kea exporter bind only to loopback.
- PF starts from a default-deny policy.

## Storage

The parent VM dataset uses compression, disabled access-time updates, metadata-only ARC caching, and standard synchronous-write semantics. `volblocksize` is selected when each zvol is created; it is not a normal inheritable dataset default.

The example vm-bhyve template uses a sparse zvol. `disk0_opts` contains only options accepted by bhyve. ZFS creation properties must be applied separately.

## Known limits

- `vm info` is human-readable output, so MAC extraction remains an adapter boundary.
- Shell traps provide best-effort compensation, not crash-safe distributed transactions.
- Interface names, Kea hook paths, and package versions vary by FreeBSD release and repository branch.
- ISC does not publish native FreeBSD packages for Stork. The installer therefore builds a pinned ISC source release and installs FreeBSD rc.d services.
