# Configuration

`cpctl` uses strict TOML decoding. Unknown keys and invalid values are rejected rather than ignored.

## Site configuration

Default path:

```text
/usr/local/etc/bkcp/site.toml
```

Override it with `--config PATH`.

Start from `config/site.example.toml`.

### Root fields

| Field | Purpose |
|---|---|
| `schema` | Configuration schema version. Currently `1`. |
| `control_plane_id` | Stable identity for this control plane. Participates in operation identity and locking. |

Do not casually change `control_plane_id` after initializing state.

### `[host]`

| Field | Purpose |
|---|---|
| `external_interface` | Host uplink interface. |
| `management_interface` | Management interface or VLAN. |
| `vm_bridge` | Bridge used by VM interfaces. |
| `vm_dataset` | ZFS dataset that will contain VM storage. |
| `vm_root` | Filesystem path corresponding to the VM dataset. |

Current `doctor` checks these values. Future drivers will use them for host mutation.

### `[database]`

| Field | Purpose |
|---|---|
| `dsn` | PostgreSQL connection string for control-plane state. |

The DSN is read from configuration and is not written into state or operation payloads. Prefer local socket or credential-file based authentication where practical.

### `[kea]`

| Field | Purpose |
|---|---|
| `api_url` | Kea Control Agent endpoint. |
| `username_file` | File containing the API username. |
| `password_file` | File containing the API password. |
| `hosts_database` | Kea hosts database name. |
| `request_timeout_ms` | Control Agent request timeout. |

Credential contents must not appear in TOML, logs, PostgreSQL state, or generated plans.

### `[network]`

| Field | Purpose |
|---|---|
| `pf_anchor` | Dedicated PF anchor name, normally `bkcp`. |
| `manage_anchor` | Whether future execution may manage the anchor contents. |

V2 must never replace the global `/etc/pf.conf` policy.

### `[[pools]]`

Each pool declares an address-allocation domain:

| Field | Purpose |
|---|---|
| `name` | Stable manifest-facing pool name. |
| `subnet` | CIDR subnet. |
| `first_host`, `last_host` | Assignable address range. |
| `gateway` | Guest default gateway. |
| `dns_servers` | Guest DNS server list. |
| `vlan` | VLAN identifier. |
| `kea_subnet_id` | Corresponding Kea subnet ID. |

The current implementation validates references but does not allocate or reserve addresses.

### `[[images]]`

| Field | Purpose |
|---|---|
| `name` | Stable manifest-facing image name. |
| `url` | Source artifact URL. |
| `compressed_sha256` | Independently verified digest of the compressed artifact. |
| `format` | Image packaging format, such as `raw.xz`. |
| `loader` | `vm-bhyve` loader selection. |

The all-zero digest in the example is deliberately unusable for trusted execution.

## VM manifest

Start from `config/vms/freebsd-node.example.toml`.

| Field | Purpose |
|---|---|
| `schema` | Manifest schema version. Currently `1`. |
| `name` | Stable VM resource name. |
| `owner` | Administrative owner label. |
| `image` | Name of a declared site image. |
| `profile` | Guest profile, currently retained as typed intent. |
| `pool` | Name of a declared address pool. |
| `desired_power` | Requested state, such as `running`. |
| `cpus` | Virtual CPU count. |
| `memory_mb` | Memory in MiB. |
| `disk_gb` | Disk size in GiB. |
| `ssh_public_key_file` | Path to an SSH public key file. The key content is not persisted in state. |

## Reference validation

`cpctl plan` rejects a manifest whose `image` or `pool` is not declared by the selected site configuration.

## Versioning rules

- Increment a schema version only for an intentional contract revision.
- Keep older readers from silently accepting unknown fields.
- Treat normalized values, not source formatting, as the declared-state identity.
- A changed normalized manifest creates a later generation; a formatting-only change does not.