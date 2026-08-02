# Roadmap

The roadmap preserves the rule that plans and journals must exist before any external mutation.

## Completed foundation

- V2-only `main` branch and frozen `legacy/v1-shell` branch.
- Strict versioned site and VM configuration.
- Deterministic normalization, plans, step digests, and idempotency keys.
- FreeBSD dependency doctor probes.
- Embedded checksummed PostgreSQL migrations.
- Dedicated `bkcp` four-state schema.
- Transactional generation assignment and operation preparation.
- Read-only status and inspection commands.
- PostgreSQL 16 race-enabled integration CI.

## Next: allocation contracts

Implement durable allocation without external execution:

- deterministic IP selection from configured pools;
- locally administered MAC generation;
- dataset and zvol naming;
- image digest binding;
- allocation uniqueness and release rules;
- concurrency and exhaustion tests.

Allocated values must survive restarts and repeated planning.

## Next: observation collectors

Add read-only collectors for:

- `vm-bhyve` inventory and power state;
- ZFS datasets and zvols;
- Kea reservations;
- cloud-init seed artifacts;
- PF anchor state.

Collectors must represent unavailable, unknown, present, and absent distinctly.

## Next: typed drivers

Implement idempotent drivers with explicit postconditions:

- image cache;
- ZFS storage;
- cloud-init seed generation;
- Kea reservation management;
- `vm-bhyve` definition and lifecycle;
- PF anchor rules.

Each driver action must be independently retryable.

## Next: resumable `apply`

Expose public execution only after driver contracts exist.

Expected flow:

```text
load and validate manifest
prepare or reuse persisted operation
collect current observations
execute first incomplete step
verify postcondition
persist step success
repeat
collect final observations
derive effective state
```

Crashes must resume from the first unverified postcondition, not restart blindly.

## Next: delete

Deletion must be a separate deterministic operation with ordered safety checks, reservation release, storage policy, and confirmed absence. Destructive storage behavior must be explicit rather than inferred.

## Next: V1 import and adoption

Import reads V1 state without modifying it. Adoption must preserve:

- IP address;
- MAC address;
- storage identity;
- guest name;
- Kea reservation identity.

No existing resource becomes V2-managed without explicit approval and verification.

## Later capabilities

- scheduled reconciliation daemon;
- drift reports and repair plans;
- Stork integration;
- Prometheus metrics and structured logs;
- Unbound DNS updates;
- FreeBSD package and service installation;
- release packaging and signed artifacts;
- dedicated FreeBSD bare-metal CI.

## Definition of executable V2

The control plane becomes operationally executable when:

- allocations are durable and concurrency-safe;
- every external driver is idempotent;
- every step has a verified postcondition;
- interrupted operations resume safely;
- unknown observations never become absence;
- apply and delete pass PostgreSQL and FreeBSD integration tests;
- V1 adoption preserves existing identities;
- operator documentation matches the shipped command surface.