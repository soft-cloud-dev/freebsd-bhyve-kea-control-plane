# V2-Only Bare-Metal Three-Node Bootstrap

This runbook defines the V2-only path for building one FreeBSD bare-metal control-plane host and three FreeBSD `vm-bhyve` guests.

It does not use `legacy/v1-shell` and does not require importing or adopting V1 resources.

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

The bare-metal host owns:

- ZFS and `vm-bhyve`;
- PostgreSQL V2 state;
- Kea DHCP4 and Kea Control Agent;
- Unbound DNS when enabled;
- PF routing and isolation;
- image cache and cloud-init seed artifacts.

The guests are ordinary FreeBSD VMs. Any jail, WireGuard, Kubernetes, database, or application topology inside them is a separate workload layer.

## Current V2 limitation

The current `main` branch is stateful but non-executing.

It already provides:

- strict site and VM TOML validation;
- deterministic normalization and plans;
- specification, plan, step-input, and idempotency digests;
- checksummed PostgreSQL migrations;
- declared, allocated, observed, and effective state contracts;
- durable operation and ordered-step journals;
- read-only dependency, status, and inspection commands.

It does not yet provide:

- durable IP, MAC, dataset, zvol, or image allocations;
- image download, verification, or promotion;
- cloud-init seed generation;
- Kea reservation mutation;
- ZFS, PF, service, or `vm-bhyve` mutation;
- observation collectors;
- a resumable executor;
- public `apply`, `delete`, or `reconcile` commands.

Therefore, a real V2-only bootstrap requires implementing the execution vertical slice described below. Installing V1 is not part of the target design.

## Required V2 vertical slice

### 1. Durable allocation

Implement allocation before any external mutation.

For each VM, persist:

- IP address from the selected site pool;
- locally administered MAC address;
- dataset and zvol names;
- Kea subnet identifier;
- image name and verified digest;
- allocation generation.

Requirements:

- one PostgreSQL transaction;
- transaction-scoped per-resource advisory lock;
- uniqueness constraints for IP, MAC, dataset, and zvol;
- deterministic retry behavior;
- pool exhaustion as a typed blocked condition;
- no allocation changes when identical intent is reapplied.

Suggested package boundary:

```text
internal/allocation/
internal/state/postgres/allocation.go
```

### 2. Read-only observations

Add collectors for:

- `vm-bhyve` guest existence and power state;
- ZFS dataset and zvol state;
- Kea reservation state;
- cloud-init seed artifact state;
- PF anchor state;
- image-cache state.

Every collector must return one of:

```text
unknown
unavailable
absent
present
```

Power state additionally distinguishes `running` and `stopped`.

Unavailable evidence must never be converted into confirmed absence.

Suggested package boundary:

```text
internal/observe/
internal/observe/vmbhyve/
internal/observe/zfs/
internal/observe/kea/
internal/observe/seed/
internal/observe/pf/
internal/observe/image/
```

### 3. Typed idempotent drivers

Implement drivers with explicit preconditions, actions, and postconditions.

Required drivers:

```text
internal/driver/image/
internal/driver/zfs/
internal/driver/cloudinit/
internal/driver/kea/
internal/driver/vmbhyve/
internal/driver/pf/
```

Each driver must:

- accept typed input rather than arbitrary shell text;
- validate that persisted step input matches its digest;
- detect an already-satisfied postcondition;
- perform one bounded mutation;
- verify the postcondition through the authoritative system;
- return typed retryable, blocked, or terminal errors;
- avoid logging credentials or private key material.

#### Image driver

- download into a temporary path;
- verify the independently configured compressed SHA-256 digest;
- decompress into a temporary raw image;
- calculate and persist the raw-image digest;
- atomically promote into the cache;
- reject the all-zero example digest.

#### ZFS driver

- create the per-VM dataset and zvol;
- verify dataset and zvol properties;
- write the verified raw image only when the target is newly created or explicitly authorized;
- never infer destructive resize or replacement behavior.

#### Cloud-init driver

- render deterministic `meta-data` and `user-data`;
- validate the referenced SSH public key;
- create a deterministic NoCloud `cidata` ISO;
- use restrictive temporary-file permissions;
- persist and verify the artifact digest.

#### Kea driver

- use the configured Control Agent and credential files;
- create or update the PostgreSQL-backed reservation;
- verify subnet, MAC, IP, and hostname after mutation;
- keep Kea's hosts database authoritative for reservations.

#### `vm-bhyve` driver

- create or update the guest definition;
- bind the allocated MAC, zvol, image loader, bridge switch, and seed ISO;
- start or stop according to declared power intent;
- verify guest existence and power state through `vm-bhyve`.

#### PF driver

- render only the configured dedicated anchor;
- validate rules before loading;
- never replace `/etc/pf.conf`;
- verify the loaded anchor digest.

### 4. Resumable executor

Implement an executor that consumes the persisted operation and ordered step journal.

Suggested package boundary:

```text
internal/executor/
internal/reconcile/
```

Execution contract:

```text
load persisted operation
verify generation and plan digest
collect current observations
find first incomplete step
verify its input digest
check whether postcondition already holds
execute one typed driver action when required
verify postcondition
persist step success
repeat
collect final observations
derive effective state
```

Crash recovery must resume from the first step whose postcondition is not verified. It must not rerun the entire operation blindly.

### 5. Public V2 commands

Add the following command surface only after the allocation, observation, driver, and executor contracts exist:

```text
cpctl apply --file VM.toml [--config PATH] [--json]
cpctl reconcile NAME [--config PATH] [--json]
cpctl delete NAME [--config PATH] [--json]
```

`apply` must:

1. load and normalize the manifest;
2. allocate or reuse durable identities;
3. persist or reuse the exact operation and steps;
4. execute from the first unverified step;
5. collect final observations;
6. derive effective state;
7. return success only when the declared postcondition is verified.

### 6. FreeBSD execution tests

Linux CI remains suitable for:

- deterministic planning;
- PostgreSQL allocation and journal behavior;
- driver contract unit tests using fakes;
- executor interruption and retry tests.

A separate FreeBSD workflow or bare-metal test host is required for:

- ZFS datasets and zvols;
- `vm-bhyve` creation and lifecycle;
- PF anchors;
- Kea Control Agent integration;
- cloud-init seed boot validation;
- crash-and-resume execution tests.

## Host prerequisites

Until V2 gains a dedicated host-bootstrap command, prepare the FreeBSD host manually or through external configuration management.

Required host state:

- a supported FreeBSD release with hardware virtualization enabled;
- ZFS pool and VM dataset;
- `vm-bhyve` installed and enabled;
- management interface and VM bridge configured;
- PostgreSQL available for V2 state;
- Kea DHCP4 and authenticated loopback Control Agent;
- PF enabled with a site-owned include for the V2 anchor;
- root or narrowly delegated privileges for the V2 executor;
- trusted key-based administrative access and an independent console.

This prerequisite is not V1. It is the platform on which V2 executes.

## V2 site configuration

Create the site configuration from the checked-in example:

```sh
install -d -m 0750 /usr/local/etc/bkcp
cp config/site.example.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
```

Configure:

```text
control_plane_id
host external interface
host management interface
host VM bridge
ZFS dataset and mount point
PostgreSQL DSN
Kea Control Agent URL and credential files
PF anchor
address pool
FreeBSD image URL and verified digest
```

Keep `control_plane_id` stable after allocations begin.

## Initialize V2

```sh
git clone https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane.git
cd freebsd-bhyve-kea-control-plane

make verify
make build

bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml --offline
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml --dry-run --json
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml
bin/cpctl status --config /usr/local/etc/bkcp/site.toml
```

With the current implementation, stop here or generate plans. External mutation is not yet available.

## Define the three VMs

Create one manifest per guest:

```text
/usr/local/etc/bkcp/vms.d/freebsd-node-01.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-02.toml
/usr/local/etc/bkcp/vms.d/freebsd-node-03.toml
```

Each manifest should declare:

- stable guest name;
- owner;
- image;
- pool;
- desired power state;
- CPU, memory, and disk size;
- SSH public-key file;
- workload profile when supported.

Before `apply` exists, inspect deterministic plans:

```sh
for manifest in /usr/local/etc/bkcp/vms.d/*.toml
do
    bin/cpctl plan \
      --config /usr/local/etc/bkcp/site.toml \
      --file "$manifest" \
      --generation 1 \
      --json
done
```

## Expected V2-only bootstrap after implementation

The intended operator flow is:

```sh
bin/cpctl doctor --config /usr/local/etc/bkcp/site.toml
bin/cpctl migrate --config /usr/local/etc/bkcp/site.toml

for manifest in /usr/local/etc/bkcp/vms.d/*.toml
do
    bin/cpctl apply \
      --config /usr/local/etc/bkcp/site.toml \
      --file "$manifest" \
      --json
done

bin/cpctl status --config /usr/local/etc/bkcp/site.toml
bin/cpctl inspect freebsd-node-01 --config /usr/local/etc/bkcp/site.toml --json
bin/cpctl inspect freebsd-node-02 --config /usr/local/etc/bkcp/site.toml --json
bin/cpctl inspect freebsd-node-03 --config /usr/local/etc/bkcp/site.toml --json
```

The `apply` commands shown here are the target V2 interface. They are not available in the current release.

## Validation criteria

A node is converged only when all authoritative observations agree:

- the V2 allocation exists and is unique;
- the verified image digest matches the allocation;
- the ZFS dataset and zvol exist with expected properties;
- the seed ISO exists and matches its digest;
- the Kea reservation matches name, MAC, IP, and subnet;
- the `vm-bhyve` definition references the expected storage, bridge, MAC, and seed;
- the guest power state matches declared intent;
- the PF anchor contains the expected scoped rules;
- every operation step has a verified postcondition;
- effective state is `converged`.

A persisted operation alone is never proof of convergence.

## Definition of done

The three-node bootstrap is genuinely V2-only when:

- no script or artifact from `legacy/v1-shell` is used;
- all identities are allocated by V2 and persisted before mutation;
- all external changes pass through typed V2 drivers;
- interrupted operations resume safely;
- unavailable evidence remains distinct from absence;
- `cpctl apply` converges all three manifests from a clean FreeBSD host;
- repeated `apply` produces no unnecessary mutation;
- `cpctl status` and `inspect` explain the resulting state;
- FreeBSD integration tests cover apply, retry, interruption, drift, and delete.
