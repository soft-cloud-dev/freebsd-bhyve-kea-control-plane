# V2-Only Bare-Metal Three-Node Bootstrap

This runbook creates three new FreeBSD `vm-bhyve` guests directly through V2. It does not use `legacy/v1-shell` and does not require import or adoption.

## Target topology

```text
                         management VLAN 10
Internet / upstream -- igb0 -- vlan10: 10.0.10.2/24
                         |
                         | PF routing/NAT
                         |
                    bridge0: 10.0.20.1/24
                         |
                  vm-bhyve switch "public"
                    /          |          \
       freebsd-node-01  freebsd-node-02  freebsd-node-03
```

## Scope boundary

V2 manages the VM lifecycle:

- durable IP, MAC, dataset, zvol, Kea subnet, and image allocation;
- verified image cache;
- ZFS VM storage;
- deterministic cloud-init seed media;
- Kea reservations;
- scoped PF subanchors;
- `vm-bhyve` definition, configuration, and power;
- observations, effective state, journals, retries, and deletion.

Prepare the host manually or through external configuration management. Host installation is not yet a `cpctl` operation.

Required host state:

- supported FreeBSD with hardware virtualization enabled;
- ZFS pool and configured VM dataset;
- `vm-bhyve` installed and initialized;
- management interface and VM bridge/switch prepared;
- PostgreSQL available for V2 state;
- Kea DHCP4 and an authenticated Control Agent;
- PF enabled with a site-owned parent anchor;
- `makefs`, `unxz`, `dd`, `zfs`, `pfctl`, and `vm` available;
- trusted administrative access and an independent console.

## 1. Build V2

```sh
git clone https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
cd freebsd-bhyve-kea-control-plane

make verify
make build
install -m 0755 bin/cpctl /usr/local/sbin/cpctl
```

## 2. Configure the site

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
```

Set and verify:

```text
control_plane_id       stable identity, never casually changed
host.vm_bridge         FreeBSD bridge used by the VM network
host.vm_dataset        ZFS parent dataset
host.vm_root           matching dataset mount point
database.dsn           V2 PostgreSQL database
kea.*                  local Control Agent and credential files
network.pf_anchor      site-owned parent anchor
pools                  assignable address ranges and Kea subnet IDs
images                 URL, format, loader, and compressed SHA-256
```

Replace the all-zero example image digest. `apply` rejects it.

Keep Kea credentials in the referenced files, not in TOML or shell history.

## 3. Validate and migrate

```sh
cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
cpctl doctor --config /usr/local/etc/bkcp/site.toml

cpctl migrate \
  --config /usr/local/etc/bkcp/site.toml \
  --dry-run \
  --json

cpctl migrate --config /usr/local/etc/bkcp/site.toml
cpctl status --config /usr/local/etc/bkcp/site.toml
```

Do not continue when a required dependency probe fails.

## 4. Define the three guests

Create:

```text
/usr/local/etc/bkcp/vms.d/freebsd-node-01.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-02.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-03.toml
```

Start from the checked-in example:

```sh
install -d -m 0750 /usr/local/etc/bkcp/vms.d
cp config/vms/freebsd-node.example.toml \
  /usr/local/etc/bkcp/vms.d/freebsd-node-01.toml

sed 's/name = "freebsd-node-01"/name = "freebsd-node-02"/' \
  config/vms/freebsd-node.example.toml \
  > /usr/local/etc/bkcp/vms.d/freebsd-node-02.toml

sed 's/name = "freebsd-node-01"/name = "freebsd-node-03"/' \
  config/vms/freebsd-node.example.toml \
  > /usr/local/etc/bkcp/vms.d/freebsd-node-03.toml
```

Review every manifest. Guest names must be stable. The SSH public-key file must be readable by the executor.

## 5. Preview deterministic intent

```sh
for manifest in /usr/local/etc/bkcp/vms.d/*.toml
do
    cpctl plan \
      --config /usr/local/etc/bkcp/site.toml \
      --file "$manifest" \
      --generation 1 \
      --json
done
```

This pure preview does not allocate or mutate infrastructure. Actual generation and allocation are assigned by `apply` under PostgreSQL locks.

## 6. Apply the guests

```sh
for manifest in /usr/local/etc/bkcp/vms.d/*.toml
do
    cpctl apply \
      --config /usr/local/etc/bkcp/site.toml \
      --file "$manifest" \
      --json
done
```

For each guest, V2:

1. validates and normalizes intent;
2. assigns or reuses durable IP, MAC, dataset, zvol, Kea subnet, and image identities;
3. persists the declaration, allocation, operation, ordered steps, exact inputs, and digests;
4. acquires a session execution lock for the resource;
5. verifies or promotes the image cache;
6. creates and validates ZFS storage;
7. creates deterministic cloud-init media;
8. creates or updates the `vm-bhyve` configuration;
9. creates or updates the Kea reservation;
10. loads the scoped PF rules;
11. converges power state;
12. records authoritative observations and verified postconditions.

A crash does not discard the journal. Re-run the same `apply`; execution resumes at the first incomplete step.

## 7. Verify convergence

```sh
cpctl status --config /usr/local/etc/bkcp/site.toml

for node in freebsd-node-01 freebsd-node-02 freebsd-node-03
do
    cpctl reconcile "$node" \
      --config /usr/local/etc/bkcp/site.toml \
      --json

    cpctl inspect "$node" \
      --config /usr/local/etc/bkcp/site.toml \
      --json
done
```

A node is converged only when:

- allocation exists and remains unique;
- verified image and ZFS identity match;
- cloud-init media exists;
- Kea reservation matches subnet, MAC, IP, and hostname;
- `vm-bhyve` definition and power match declared intent;
- scoped PF rules are applied when anchor management is enabled;
- all ordered steps contain verified postconditions;
- current observations agree with the declared state.

Unavailable evidence is not absence and does not establish convergence.

## 8. Guest readiness

Obtain allocated addresses through `cpctl inspect`, then test each guest using the declared SSH key:

```sh
ssh -i /root/.ssh/id_ed25519 admin@ALLOCATED_IP \
  'uname -a; cloud-init status --wait'
```

V2 creates ordinary FreeBSD guests. Any jail, WireGuard, Kubernetes, database, or application topology inside them is a separate workload layer.

## 9. Backup

Preserve:

```text
PostgreSQL V2 database
/usr/local/etc/bkcp
Kea configuration and credential files
PF parent-anchor configuration
ZFS VM dataset
verified image cache under VM root
```

Use a PostgreSQL-consistent backup and a recursive ZFS snapshot before upgrades or destructive testing.

## 10. Controlled teardown

Deletion is explicit and destructive:

```sh
for node in freebsd-node-03 freebsd-node-02 freebsd-node-01
do
    cpctl delete "$node" \
      --config /usr/local/etc/bkcp/site.toml \
      --destroy-storage \
      --json
done
```

V2 verifies absence before releasing allocations and archiving resources. The shared verified image cache is retained.

## FreeBSD execution validation

The repository includes the manually triggered **V2 FreeBSD Execution** workflow for a protected self-hosted runner labelled:

```text
self-hosted, freebsd, bkcp
```

The workflow uses an environment named `freebsd-execution`, runs `doctor`, migrations, `apply`, `reconcile`, and `inspect`, and performs destructive cleanup only when explicitly requested.
