# Streamlined v2 Design: FreeBSD bhyve + Kea Control Plane

Status: Proposed
Target: `soft-cloud-dev/freebsd-bhyve-kea-control-plane`
Design intent: reduce runtime, build, configuration, and failure-recovery complexity while preserving the existing correctness and security invariants.

## 1. Decision

Replace the current installer-and-script collection with a small declarative control plane built around:

- one static `cpctl` binary;
- one versioned site configuration file;
- one PostgreSQL instance for inventory, allocation, operation journal, and the separate Kea hosts database;
- vm-bhyve and ZFS as the VM runtime;
- Kea DHCP4 and its loopback Control Agent as the reservation interface;
- a deterministic planner and resumable reconciler;
- optional add-ons for Stork, observability, Unbound, and opinionated host hardening.

The v2 core does not install Kubernetes tooling, build Stork, manage Grafana/Loki/Prometheus, replace the global PF policy, or harden OpenSSH.

## 2. Existing properties to preserve

The redesign keeps these properties intact:

1. PostgreSQL owns VM inventory and IP allocation state.
2. The PostgreSQL-backed Kea hosts database remains the only writable reservation store.
3. MAC addresses are allocated deterministically from a stable control-plane namespace and checked transactionally for collisions.
4. Cloud images are used only after digest verification.
5. Kea Control Agent and PostgreSQL remain local-only by default.
6. VM traffic is isolated by default-deny PF policy.
7. Provisioning and deletion are idempotent.
8. Every externally visible change is represented by durable state and can be reconciled after interruption.

## 3. Problems addressed

### 3.1 Scope coupling

The current installation path combines VM lifecycle, PostgreSQL/IPAM, Kea, Unbound, PF, SSH hardening, blacklistd, Stork, Grafana, Prometheus, Loki, exporters, cluster orchestration, and kubectl setup.

These layers have different ownership and release cycles. Failure in an optional layer must not block the VM and DHCP core.

### 3.2 Target-host compilation

The current dependency path may rebuild Kea and builds Stork from source with a large compiler and language toolchain. Production hosts should consume pinned packages and binaries, not act as build workers.

### 3.3 Configuration drift

Runtime behavior is controlled by a large set of Make variables and environment variables. Rerunning an individual stage requires reproducing the previous values exactly.

V2 moves durable configuration into a validated, versioned file. Environment variables are limited to temporary overrides and secret injection.

### 3.4 Crash recovery

Shell traps compensate normal failures but cannot guarantee recovery after host crashes, process termination, or partial external success.

V2 records plans and step outcomes before and after each external action. Re-running reconciliation resumes or repairs the operation instead of relying on rollback traps.

### 3.5 Special-case topology code

A three-node cluster and jail-host VM are currently separate lifecycle paths. V2 treats them as ordinary VM manifests referencing reusable profiles. Replica generation is a convenience command, not a separate control-plane subsystem.

## 4. Scope

### 4.1 Core

- typed site configuration;
- schema migrations;
- desired VM specifications;
- deterministic IP and MAC allocation;
- verified image cache;
- cloud-init NoCloud seed generation;
- vm-bhyve/ZFS lifecycle;
- Kea reservation lifecycle;
- plan, apply, delete, observe, reconcile, and status commands;
- PF anchor rendering for VM-network rules;
- structured operation history;
- import and adoption of existing v1 VMs.

### 4.2 Add-ons

- `addons/unbound`: local recursive resolver;
- `addons/observability`: Prometheus, exporters, Loki, Grafana, dashboards;
- `addons/stork`: read-only Stork visibility integration, disabled by default; reservation edits remain owned by `cpctl` and out-of-band edits are reported as drift;
- `addons/host-hardening`: OpenSSH and blacklistd policy examples;
- `addons/jail-services`: optional service isolation in FreeBSD jails.

### 4.3 Non-goals

- Kubernetes worker installation;
- kubectl or kubeconfig lifecycle;
- a general-purpose cluster manager;
- Stork source compilation on the target host;
- managing the operator's SSH trust policy;
- replacing `/etc/pf.conf` wholesale;
- authoritative DNS or DHCP-DDNS;
- supporting native services, jails, and a separate container CLI simultaneously in the core;
- a web UI in the first v2 release.

## 5. Architecture

```text
site.toml + vms.d/*.toml + profiles/*.yaml
                    |
                    v
                 cpctl
      +-------------+--------------+
      | normalize -> plan -> apply |
      | observe   -> derive status  |
      | journal   -> reconcile      |
      +-------------+--------------+
                    |
       +------------+-------------+
       |            |             |
   PostgreSQL    vm-bhyve/ZFS   Kea Control Agent
   desired       guest/storage   reservations
   allocation                     and leases
   observation
   effective
   operations
                    |
                 bridge0
                    |
                 bhyve VMs
```

`cpctl` is the only writer to the v2 inventory and operation journal. Kea remains responsible for its own hosts database and runtime lease state.

## 6. Execution model

### 6.1 One binary

`cpctl` is implemented in Go and shipped as a FreeBSD package or signed release binary. It directly handles:

- TOML and YAML parsing;
- PostgreSQL access;
- Kea HTTP API calls;
- canonicalization and plan hashing;
- operation journaling;
- structured JSON and human-readable output.

It invokes a small, explicit set of FreeBSD commands:

- `vm`;
- `zfs` and `zpool`;
- `sysrc` where required;
- `makefs` for NoCloud media;
- `pfctl` for validation and anchor reload;
- `service` for readiness checks.

This removes runtime dependencies on shell orchestration, `jq`, `curl`, and direct `psql` scripting.

### 6.2 No mandatory daemon

The first v2 release is CLI-driven:

```text
cpctl plan
cpctl apply
cpctl delete
cpctl reconcile
cpctl status
cpctl doctor
```

An optional rc.d service may run `cpctl reconcile --watch` or periodic one-shot reconciliation. Correctness does not depend on a permanently running process.

## 7. State model

V2 explicitly separates declared, allocated, observed, and effective state.

### 7.1 Declared state

`vm_specs` stores the normalized user intent:

- name;
- owner;
- image reference;
- profile;
- CPU, memory, and disk requirements;
- network pool;
- desired power state;
- cloud-init input digest;
- generation;
- canonical specification digest.

### 7.2 Allocated state

`vm_allocations` stores values assigned by the control plane:

- VM UUID;
- IP address;
- MAC address;
- dataset and zvol names;
- Kea subnet ID;
- image digest;
- allocation generation.

Allocation is durable and is not recomputed on every run.

### 7.3 Observed state

`vm_observations` records evidence from external systems:

- vm-bhyve definition present;
- VM running or stopped;
- configured MAC address;
- ZFS dataset and zvol presence;
- seed image digest;
- Kea reservation presence and values;
- active DHCP lease when available;
- observation timestamp;
- observation error or unavailable fields.

Unknown is represented explicitly. Missing observation is not treated as absence.

### 7.4 Effective state

`vm_effective` is derived from declared, allocated, and observed state:

- pending;
- applying;
- converged;
- degraded;
- drifted;
- deleting;
- absent;
- blocked.

The effective row contains the current plan digest, last successful reconciliation, and a machine-readable reason code.

### 7.5 Operation journal

`operations` and `operation_steps` provide crash recovery:

```text
operation
  id
  resource_uuid
  generation
  action
  plan_digest
  idempotency_key
  status
  created_at
  completed_at

operation_step
  operation_id
  sequence
  driver
  action
  input_digest
  status
  attempts
  started_at
  completed_at
  error_code
  error_detail
```

The unique idempotency key is derived from the normalized specification, resource generation, action, and stable control-plane ID.

## 8. Reconciliation semantics

### 8.1 Apply

1. Parse and strictly validate the site configuration and VM manifest.
2. Canonicalize the manifest and calculate its specification digest.
3. Acquire a per-VM PostgreSQL advisory lock.
4. Upsert declared state and increment generation only when intent changes.
5. Reuse an existing valid allocation or allocate IP, MAC, dataset, and image identity transactionally.
6. Build a deterministic plan.
7. Persist the operation and all steps before changing external state.
8. Execute idempotent `ensure` operations in order.
9. Observe each affected external domain after the operation.
10. Mark the resource converged only when effective state matches declared state.

Recommended ensure sequence:

```text
ensure verified image
ensure vm-bhyve definition
ensure zvol/image contents
ensure VM configuration
ensure cloud-init seed
ensure Kea reservation
ensure desired power state
observe all domains
```

### 8.2 Interruption

A repeated `cpctl apply` or `cpctl reconcile` finds the incomplete operation, verifies completed steps, and resumes from the first unsatisfied postcondition.

Normal failure does not trigger broad destructive rollback. The resource remains in `degraded` or `blocked` state with its allocation reserved. This avoids address reuse while a VM, zvol, reservation, or lease may still exist.

### 8.3 Delete

Deletion is desired state, not an imperative rollback shortcut:

```text
mark desired absent
stop VM
remove Kea reservation
remove active lease where safe
remove seed and VM definition
remove or retain ZFS data according to policy
release IP allocation
archive resource
observe absence
```

Deletion can be resumed after interruption. Destructive storage deletion requires an explicit policy or `--destroy-storage` flag.

### 8.4 Drift

`cpctl reconcile` reports and optionally repairs:

- inventory without vm-bhyve guest;
- guest without managed inventory;
- configured MAC mismatch;
- dataset or zvol mismatch;
- Kea reservation missing or mismatched;
- unmanaged Kea reservation using an allocated IP or MAC;
- released allocation with external state still present;
- image or seed digest mismatch;
- observation unavailable versus confirmed absence.

Unmanaged external objects are never deleted automatically.

## 9. Configuration

### 9.1 Site configuration

Default path:

```text
/usr/local/etc/bkcp/site.toml
```

Example:

```toml
schema = 1
control_plane_id = "softcloud-lab-01"

[host]
external_interface = "igb0"
management_interface = "vlan10"
vm_bridge = "bridge0"
vm_dataset = "zroot/vm"
vm_root = "/zroot/vm"

[database]
dsn = "host=/var/run/postgresql dbname=controlplane user=controlplane"

[kea]
api_url = "http://127.0.0.1:8000/"
username_file = "/usr/local/etc/kea/kea-api-user"
password_file = "/usr/local/etc/kea/kea-api-password"
hosts_database = "kea_hosts"

[network]
pf_anchor = "bkcp"
manage_anchor = true

[[pools]]
name = "vm-lan"
subnet = "10.0.20.0/24"
first_host = "10.0.20.10"
last_host = "10.0.20.99"
gateway = "10.0.20.1"
dns_servers = ["10.0.20.1"]
vlan = 20
kea_subnet_id = 1
```

Secrets are not stored in this file. It references root-readable credential files or uses PostgreSQL peer authentication.

### 9.2 Image configuration

```toml
[[images]]
name = "freebsd-14.3"
url = "https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz"
compressed_sha256 = "REQUIRED_PINNED_DIGEST"
format = "raw.xz"
loader = "bhyveload"
```

Production configuration requires an explicitly pinned digest. Fetching a checksum from the same origin may remain available only as an interactive bootstrap mode.

### 9.3 VM manifest

```toml
schema = 1
name = "freebsd-node-01"
owner = "admin"
image = "freebsd-14.3"
profile = "jail-host"
pool = "vm-lan"
desired_power = "running"
cpus = 2
memory_mb = 4096
disk_gb = 32
ssh_public_key_file = "/root/.ssh/id_ed25519.pub"
```

A three-node topology is represented by three manifests or generated with:

```sh
cpctl generate vm-set \
  --name freebsd-node \
  --replicas 3 \
  --profile jail-host \
  --image freebsd-14.3 \
  --pool vm-lan \
  --output vms.d
```

The generated files are ordinary VM manifests. No cluster-specific lifecycle code is required.

## 10. CLI contract

```text
cpctl doctor
cpctl migrate
cpctl plan -f vms.d/freebsd-node-01.toml
cpctl apply -f vms.d/freebsd-node-01.toml
cpctl apply -d vms.d
cpctl status [--json]
cpctl inspect <name> [--json]
cpctl reconcile [<name>] [--repair]
cpctl delete <name> [--destroy-storage]
cpctl image fetch <name>
cpctl import-v1 [--dry-run]
cpctl adopt <name>
```

Behavioral requirements:

- all mutating commands support `--dry-run` where meaningful;
- machine-readable output is stable and versioned;
- exit codes distinguish invalid input, unavailable dependency, drift, blocked operation, and partial failure;
- plan output is deterministic for identical normalized inputs;
- secrets are redacted from logs and JSON output;
- commands use per-resource locks and are safe to repeat.

## 11. Networking and PF

V2 does not replace the site's global `/etc/pf.conf`.

The operator adds or approves dedicated site-level PF anchor declarations for the control-plane filter and NAT rules. The exact stanza is generated for the supported FreeBSD release rather than replacing the complete ruleset.

`cpctl network render` writes atomic anchor files containing only:

- VM LAN NAT when enabled;
- DHCP traffic for the configured bridge;
- optional DNS traffic to configured local resolver addresses;
- blocks from VM LAN to the host and management network;
- outbound VM traffic allowed by site policy.

`pfctl -nf` validates the complete ruleset before reload. Site SSH, blacklistd, management UI, and unrelated service rules remain site-owned.

## 12. Service deployment choice

The v2 core supports one deployment model: native FreeBSD rc.d services on the bhyve host.

This is the smallest operational surface and matches the privileged nature of vm-bhyve and ZFS administration. Jail isolation can be added later through `addons/jail-services`, but it must not create a second core execution path.

Core services:

- PostgreSQL;
- Kea DHCP4;
- Kea Control Agent;
- vm-bhyve.

Unbound is optional. External DNS servers may be supplied directly by the pool configuration.

## 13. Build and package pipeline

Target hosts do not compile Kea or Stork.

### 13.1 Artifacts

Publish:

- `cpctl` FreeBSD packages for supported release/architecture pairs;
- a Kea package with the required PostgreSQL and host-command hooks;
- checksums, signatures, provenance, and an SBOM;
- a small pkg repository metadata set.

### 13.2 CI layers

1. Portable unit tests on Linux:
   - config parsing;
   - normalization;
   - deterministic planning;
   - plan and idempotency hashes;
   - state derivation;
   - fake drivers.
2. PostgreSQL/Kea contract tests:
   - migrations;
   - allocation concurrency;
   - reservation add/get/delete;
   - operation resume.
3. FreeBSD VM integration:
   - package installation;
   - config validation;
   - native service readiness;
   - PF anchor rendering and syntax.
4. Bare-metal bhyve E2E:
   - provision;
   - DHCP and SSH readiness;
   - interrupted-operation resume;
   - drift detection;
   - delete and allocation release.
5. Package release:
   - immutable action pins;
   - signed artifacts;
   - exact artifact promoted from integration to release.

The integration job must test the same PostgreSQL-enabled Kea package distributed to target hosts. Testing an in-memory substitute is not a release gate for the production reservation path.

## 14. Repository layout

```text
.
├── cmd/
│   └── cpctl/
├── internal/
│   ├── config/
│   ├── model/
│   ├── normalize/
│   ├── planner/
│   ├── reconcile/
│   ├── state/postgres/
│   └── driver/
│       ├── cloudinit/
│       ├── image/
│       ├── kea/
│       ├── pf/
│       ├── vmbhyve/
│       └── zfs/
├── migrations/
├── config/
│   ├── site.example.toml
│   └── profiles/
│       ├── freebsd.yaml
│       └── jail-host.yaml
├── packaging/
│   └── freebsd/
├── addons/
│   ├── host-hardening/
│   ├── jail-services/
│   ├── observability/
│   ├── stork/
│   └── unbound/
├── tests/
│   ├── contract/
│   ├── integration/
│   └── e2e/
├── docs/
│   ├── DESIGN.md
│   ├── MIGRATION.md
│   ├── OPERATIONS.md
│   └── SECURITY.md
├── go.mod
├── Makefile
└── README.md
```

The Makefile is development-only:

```text
make build
make lint
make test
make verify
make package-freebsd
```

Runtime configuration is never passed through a long Make invocation.

## 15. Migration from v1

### Phase 0: freeze and identify

- tag the current shell implementation as `v1-shell`;
- document its supported FreeBSD, PostgreSQL, and Kea versions;
- stop adding new topology-specific shell workflows.

### Phase 1: design and read-only inspection

- add v2 schema migrations;
- implement `cpctl doctor`, `status`, and `import-v1 --dry-run`;
- read existing `ipam_pools`, `ipam_leases`, and `vms` rows;
- inspect vm-bhyve, ZFS, and Kea without changing state.

### Phase 2: import and adoption

- import existing rows as `managed = false`;
- store observations and identify mismatches;
- require `cpctl adopt <name>` before v2 may mutate a VM;
- adoption succeeds only when inventory, vm-bhyve, ZFS, and Kea agree.

### Phase 3: v2 lifecycle

- implement plan/apply/reconcile/delete;
- use the existing verified image cache where its marker validates;
- retain existing IP and MAC allocations;
- make old provision/deprovision targets thin wrappers around `cpctl`.

### Phase 4: extract optional layers

- move Stork, observability, Unbound, host hardening, and jail service examples under `addons/`;
- default all add-ons to disabled;
- remove kubectl and cluster lifecycle from core.

### Phase 5: remove shell compatibility

- remove wrappers after one documented migration release;
- keep a standalone v1 branch and migration guide.

## 16. Pull request sequence

### PR 1 — Freeze v2 contract

- add `docs/DESIGN.md` and `docs/MIGRATION.md`;
- define site and VM schemas;
- define stable JSON output and exit codes;
- record non-goals.

### PR 2 — `cpctl` skeleton and doctor

- initialize Go module;
- strict config parser;
- command framework;
- dependency inspection;
- read-only vm-bhyve, ZFS, Kea, and PostgreSQL probes.

### PR 3 — State schema and deterministic planner

- declared/allocated/observed/effective tables;
- operation journal;
- canonicalization and plan digest;
- idempotency and concurrency tests.

### PR 4 — Core drivers and VM apply

- verified image cache;
- cloud-init seed;
- vm-bhyve and ZFS ensure operations;
- Kea reservation driver;
- resumable apply.

### PR 5 — Delete, drift, and reconciliation

- safe deletion workflow;
- observation collection;
- effective-state derivation;
- interrupted-operation and fault tests.

### PR 6 — v1 import and adoption

- read current schema;
- import existing resources unmanaged;
- adoption validation;
- compatibility wrappers.

### PR 7 — FreeBSD packages and exact-artifact CI

- cpctl package;
- PostgreSQL-enabled Kea package;
- package repository;
- signed release artifacts;
- integration tests against released package candidates.

### PR 8 — Add-on extraction

- Stork;
- observability;
- Unbound;
- host hardening;
- jail services;
- removal of cluster/kubectl code from core.

## 17. Definition of done

The streamlined v2 is complete when:

1. A fresh supported FreeBSD host needs no compiler or language toolchain.
2. Core installation consumes signed packages and one site configuration file.
3. `cpctl apply` is deterministic and idempotent.
4. Identical normalized inputs produce the same plan and idempotency key.
5. A killed apply operation resumes without manual database editing.
6. Unknown observations are distinct from confirmed absence.
7. The core uses one runtime deployment model.
8. The core does not install Stork, Grafana, Loki, Prometheus, Unbound, kubectl, or SSH policy by default.
9. PF integration is anchor-scoped and does not replace the site's ruleset.
10. Existing v1 VMs can be imported and adopted without reallocating IP or MAC addresses.
11. A three-node jail-host topology is represented by ordinary VM manifests.
12. The exact PostgreSQL-enabled Kea package distributed to users passes integration tests.
13. Bare-metal E2E verifies provision, interruption recovery, drift detection, and deletion.
14. `make verify` runs all portable tests and produces machine-readable test results.

## 18. Minimal operator workflow

```sh
pkg install bkcp kea-pgsql postgresql16-server vm-bhyve
cp /usr/local/share/examples/bkcp/site.toml /usr/local/etc/bkcp/site.toml
vi /usr/local/etc/bkcp/site.toml
service postgresql enable
service postgresql start
cpctl migrate
cpctl doctor
cpctl image fetch freebsd-14.3
cpctl plan -f vms.d/freebsd-node-01.toml
cpctl apply -f vms.d/freebsd-node-01.toml
cpctl status
```

The normal day-two workflow is limited to:

```sh
cpctl apply -d vms.d
cpctl reconcile
cpctl status
```
