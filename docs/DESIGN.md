# V2 implementation contract

The canonical architecture is defined in [streamlined-v2.md](streamlined-v2.md).

## Implemented VM lifecycle

- Static Go `cpctl` CLI.
- Strict TOML site and VM manifest decoding with unknown-key rejection.
- Versioned JSON schemas for site and VM configuration.
- Deterministic normalization, specification digests, pure plan digests, allocation-bound step inputs, executable plan digests, and idempotency keys.
- Read-only `doctor` checks for FreeBSD, required executables, ZFS, PostgreSQL, and Kea.
- Embedded immutable PostgreSQL migrations with advisory locking and SHA-256 checksum verification.
- Separate declared, allocated, observed, and effective state under the `bkcp` schema.
- Transactional, concurrency-safe IP, MAC, dataset, zvol, Kea subnet, and image allocation.
- Exact persisted operation-step input JSON and input digests.
- Verified postcondition JSON and postcondition digests.
- Shared preparation/execution advisory-lock namespace and process-crash lock release.
- Typed FreeBSD service, image, ZFS, cloud-init, Kea, PF, and `vm-bhyve` operations.
- Explicit unavailable, unknown, absent, and present observations.
- Resumable `apply`, observation-only `reconcile`, and guarded destructive `delete`.
- Read-only `status` and evidence-rich `inspect`.
- Stable JSON response envelope and explicit exit codes.

## Scope boundary

V2 manages new VM resources when the FreeBSD substrate already exists. It does not yet install or upgrade:

- the FreeBSD base system;
- packages;
- PostgreSQL or Kea servers;
- physical interfaces, VLANs, or the site bridge;
- the site-owned parent PF policy;
- SSH trust or general host hardening.

Optional service management may start and verify only explicitly configured rc.d services. It is not a package installer or general root shell.

Import and adoption of existing V1 resources remain separate future operations.

## State contract

The four state classes are independent:

- **Declared** — append-only normalized intent by generation.
- **Allocated** — durable identity-bearing assignments, retained across retries.
- **Observed** — timestamped authoritative evidence with explicit availability semantics.
- **Effective** — derived reconciliation state and machine-readable reason.

No missing or unavailable observation is treated as confirmed absence.

## Execution contract

Before external mutation, apply preparation:

1. acquires the execution-key transaction lock;
2. acquires the transaction-scoped resource lock;
3. retains or advances declared generation;
4. allocates or reuses concrete identities under the pool lock;
5. builds the allocation-bound executable plan;
6. persists operation, exact ordered inputs, digests, and pending state;
7. commits.

The executor then:

1. acquires the same execution key as a PostgreSQL session advisory lock;
2. re-reads the current persisted operation;
3. resumes at the first incomplete step;
4. decodes and re-hashes the persisted input;
5. invokes one typed action;
6. verifies its authoritative postcondition;
7. persists postcondition JSON and digest;
8. records final observations;
9. marks effective state converged or verified absent.

A process crash releases the session lock. Re-running the same operation resumes from durable evidence.

## Driver safety rules

- Image bytes are promoted only after compressed-digest verification; the all-zero sentinel is rejected.
- Existing ZFS storage is not overwritten when image identity is missing or different.
- Cloud-init media reuse is bound to deterministic source and ISO digests.
- Kea reservations are verified by subnet, MAC, IP, and hostname.
- PF writes are limited to the configured per-resource subanchor and verified after load or flush.
- `vm-bhyve` configuration is generated from typed fields and uses the configured switch identity.
- Service names must match a restricted identifier pattern and must be listed explicitly.
- Delete requires `--destroy-storage` and releases allocation only after verified absence.

## Determinism contract

Identical normalized intent, control-plane ID, generation, durable allocation, action, site execution policy, and ordered step contract produce identical:

- `spec_digest`;
- exact `input_json` values;
- step `input_digest` values;
- executable `plan_digest`;
- `idempotency_key`.

Identical intent retains the generation and allocation. Changed intent advances generation once under locks. Pool or image replacement is blocked rather than inferred.

## JSON envelope

```json
{
  "schema": 1,
  "command": "apply",
  "ok": true,
  "data": {},
  "errors": []
}
```

Fields may be added backward-compatibly while `schema` remains `1`.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | verified success |
| 2 | invalid input or contract violation |
| 3 | required dependency unavailable |
| 4 | drift detected |
| 5 | operation, allocation, or migration blocked |
| 6 | partial or retryable failure |
| 7 | resource not found |
| 70 | internal error |
